## What the web build mounts, decided by the URL the visitor arrived on.
##
## ## The defect this module exists to close
##
## `https://ide.codetracer.com/noir` opened the welcome screen. So did `/`, and
## so did every other address the deployment serves, because `ui_js.nim`'s web
## arm called `mountWebWelcomeScreen()` unconditionally and asked nothing about
## the location.
##
## The machinery to ask was already there, complete and tested, and had never
## been called by anything:
##
##   * `platform/web_entry.classifyPath` — `/noir` → `efBare` with
##     `languageEntry == "noir"`; asserted at `test_platform_web.nim:460`.
##   * `platform/web_entry.resolveEntry` — §1b.3's six steps, with a table test
##     per row.
##   * `host/web_browser.currentEntryRequest` — the browser's location, in the
##     shape `web_entry` wants. **Zero callers**, including its own module.
##
## Three correct components and no wire between them and the product. This
## module is the wire, and `ci/test/web-renderer-mounts.sh`'s route arm is the
## check that it stays one — the previous gate loaded `/` only, so a router
## that ignored the path was indistinguishable from one that honoured it.
##
## ## Why this no longer reads the location itself
##
## It used to, and the duplication was forced rather than chosen. `boot()`
## resolves the entry too and reports it on the boot line, and it could not
## HAND the resolution over: `web.js` and `ui.js` were separately compiled Nim
## programs, each wrapped in its own IIFE by `ci/test/web-bundle-assets.sh`, so
## there was no shared value for them to share. This module therefore carried
## its own `jsEntryPath` / `jsEntryOrigin` / `jsEntryHash` / `jsEntrySearch`,
## byte-identical to `host/web_browser`'s.
##
## NS9 merged the two programs, and the duplication went from necessary to
## hazardous — two readers of one browser API, in one bundle, free to drift.
## `currentRendererEntryRequest` now calls `host/web_browser.currentEntryRequest`
## and the four `importjs` bodies are gone. The location has one implementation.
##
## THE GATE FOUND THIS, WHICH IS THE PART WORTH RECORDING.
## `ci/test/web-renderer-mounts.sh`'s arm S substitutes the single emitted
## `String(window.location.pathname || '/')` and asserts there is exactly one.
## The merged bundle had two, arm S failed with "could not be measured", and
## the redundancy was named by a check rather than noticed by a reader.
##
## What was NEVER duplicated is the part that matters most, and it is unchanged:
## `classifyPath` and `resolveEntry` come from `platform/web_entry`, so the
## renderer and the boot sequence reach the same verdict from the same code.
## `web_entry.classifyPath`'s own header names the hazard — "two
## implementations of *which prefixes exist* is how a form reaches the SPA in
## the code and 404s at the CDN" — and that classification has, and always had,
## exactly one implementation.
##
## The renderer still ASKS separately rather than being handed `boot.entry`,
## and that is deliberate: `boot()` is allowed to REFUSE (§4.5), and a refused
## boot must still mount something at the right address — "never a blank
## editor, never an error page". Asking keeps that true without a branch.
##
## ## Why `/` still gets the welcome screen, and `/noir` does not
##
## Rule 0: "The language is an entry point, not a namespace." `classifyPath`
## gives `/noir` `languageEntry == "noir"` and gives `/` the empty string, and
## rule 0 is what makes that difference meaningful — `/noir` "sets a visitor up
## with the **right initial template**", and `/` names no language so there is
## no right template to pick. Defaulting `/` to Noir would make Noir the
## product's default language, which is exactly the permanent classification
## rule 0 refuses.
##
## So the split is not a special case for one path; it is the presence or
## absence of the field the classifier already fills in, and
## `platform/noir_template.templateFor` returns `emptyTemplate()` for the empty
## language for the same reason.
##
## ## What this claims, and what it does not
##
## `/noir` now enters **edit mode** on the bundled template, and it does so
## through the message the desktop enters edit mode with —
## `CODETRACER::no-trace`. There is no web-specific mounting path any more;
## `mountTemplateSurface`, which drew a Filesystem panel into `<section
## id="main">` and nothing else, is deleted. See `templateNoTracePayload`.
##
## §1a's picture also shows **Test Results** and **Constraints**, and they are
## here now — as `Content.TestResults` and `Content.Constraints`, ordinary
## CodeTracer panes with IsoNim views, in `src/config/default_layout.json`'s
## right-hand column and absent from `editModeHiddenContentIds`, which together
## is the whole of "both platforms get them". Building them in the browser only
## would have made the web a fork of the product, which is what §3 exists to
## prevent; building them in `Content` means a desktop `ct edit` on a Noir
## crate gets both from the same declaration.
##
## What this module supplies is the WEB HOST's answer to the one message they
## are fed by — see `installTemplatePaneHost`. The Electron host's answer is
## `index/ns9_panes.nim`, and the renderer cannot tell which replied.

import
  std/[ json, strutils ],
  ui_imports

import ../viewmodel/platform/web_entry
import ../viewmodel/platform/web_deployment
import ../viewmodel/platform/noir_template
import ./web_replay_host
# The one mutable project, and the path helpers that used to be defined here.
# They moved because the save host needs all three to turn an absolute renderer
# path into the project-relative key the store is keyed by, and a second copy
# of "where the project is rooted" is exactly what `templateProjectRoot`'s own
# doc comment warns against. Re-exported so this module's importers are
# unaffected by the move.
import ./web_project_store
export templateProjectRoot, templateFilePath, templateFileFor, projectRelative
# The Noir toolchain driver, for ONE proc: whether this deployment can run the
# tests. `web_project_store` was split out of this module so `web_noir_build`
# could import the project without importing the surface, so the dependency
# runs this way and only this way.
from ./web_noir_build import noirTestRunAbsence
import ./mode_layouts
export mode_layouts.layoutComponents
from ../edit_mode import chooseInitialEditPath
from ../../ct_test/contracts import TestCatalog
from ../../ct_test/frameworks/noir_test_syntax import
  NoirSourceFile, noirCatalogFromSources
from ../../common/noir_constraints import
  ConstraintReport, parseNargoInfoJson, absentReport
from ../../ct_test/contracts import toJson

when defined(js):
  # THE LOCATION IS READ ONCE, IN ONE PLACE, and that place is
  # `host/web_browser.currentEntryRequest`.
  #
  # This module used to carry its own `jsEntryPath`, `jsEntryOrigin`,
  # `jsEntryHash` and `jsEntrySearch` — four `importjs` bodies byte-identical
  # to the host module's. That was forced rather than chosen: `web.js` and
  # `ui.js` were separately compiled Nim programs and there was no shared value
  # for them to share, so the read had to exist on both sides.
  #
  # NS9 merged the arms, and the duplication stopped being a necessity and
  # became a hazard — two readers of one browser API in one program, free to
  # drift. It was also immediately DETECTED, which is the part worth recording:
  # `ci/test/web-renderer-mounts.sh`'s arm S substitutes the single emitted
  # `String(window.location.pathname || '/')` and asserts there is exactly one
  # of them. The merged bundle had two, the assertion failed, and the gate
  # named the redundancy before a human noticed it.
  #
  # `jsReplaceHistoryEntry` below stays here: it WRITES the location and the
  # host module has no counterpart, so it is not a second implementation of
  # anything.
  from ../viewmodel/host/web_browser import currentEntryRequest

  proc jsDeploymentText(): cstring {.importjs: """
(function () {
  try {
    if (typeof document !== 'undefined') {
      var el = document.getElementById('codetracer-deployment');
      if (el) { return String(el.textContent || ''); }
    }
  } catch (e) {}
  return '';
})()""".}
    ## The deployment's own description of itself, read OUT OF THE DOM.
    ##
    ## The renderer needs one fact from it — whether this origin is a language
    ## entry point, so that `noirstudio.dev/` means what
    ## `ide.codetracer.com/noir` means — and it must not cost a request:
    ## `ci/test/noir-studio-signed-out.sh` asserts the development loop has
    ## ZERO egress sites and a `fetch` here would be the first.
    ##
    ## The element id is spelled here rather than imported as
    ## `deploymentDescriptorElementId` because an `importjs` pattern is a
    ## compile-time string, not an expression — the same constraint
    ## `host/web_browser.jsDeploymentDescriptorText` works under, which takes
    ## the id as a parameter for exactly this reason.
    ##
    ## The two spellings are kept honest by arm O of
    ## `ci/test/web-renderer-mounts.sh`: a mismatch makes this read return the
    ## empty string, `languageForOrigin` answer "", and the language host fall
    ## back to the language-neutral root — which is precisely what that arm
    ## loads a second origin to detect. A drift here cannot be silent.

  proc jsReplaceHistoryEntry*(path: cstring) {.importjs: """
(function (p) {
  try {
    if (typeof window !== 'undefined' && window.history &&
        typeof window.history.replaceState === 'function') {
      window.history.replaceState(null, '', p);
    }
  } catch (e) {}
})(#)""".}
    ## Rule 5's third row: `/noir/new` "instantiates a fresh template and
    ## **replaces** the history entry so Back does not re-trigger it".
    ##
    ## `replaceState`, never `pushState`, and never `location.assign` — the
    ## first would leave `/noir/new` on the stack (Back re-triggers it, which
    ## is the whole thing the rule forbids) and the second would reload the
    ## document, which is a navigation and would re-run the arrival it is
    ## supposed to be replacing.
    ##
    ## This is also the reason `renderRewriteConfig` insists on a 200-rewrite:
    ## the rewritten address stays `/noir/new` in the browser, so there is a
    ## history entry to replace. Under the 308 the deployment was serving,
    ## `replaceState` would have been rewriting `/` — see
    ## `web_deployment.entryDocumentAddress`.

  proc jsDownloadTextFile*(filename, contents: cstring): bool {.importjs: """
(function (n, c) {
  try {
    var blob = new Blob([c], {type: 'text/plain;charset=utf-8'});
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = n;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 0);
    return true;
  } catch (e) {
    console.error('codetracer-web: download of ' + n + ' failed', e);
    return false;
  }
})(#, #)""".}
    ## ISSUE #735 — A BROWSER TAB'S "SAVE AS", and the only one it has.
    ##
    ## `Noir-Studio.md` §4.1 puts three tiers in order and names the top one
    ## *"durable storage the user owns"*; OPFS is explicitly not it. A download
    ## is: the bytes leave the origin's sandbox and land wherever the browser's
    ## own save dialog puts them, under a name the user can change, on a
    ## filesystem the product has no further claim on. That is what saving an
    ## untitled buffer MEANS, so it is what this arm does — rather than writing
    ## into the OPFS working copy, which would be the "periodic snapshot"
    ## mistake §4.1 refuses: work the user believes is saved, held somewhere a
    ## storage-pressure eviction can take.
    ##
    ## Returns whether the click was issued. It cannot report what the user did
    ## with the save dialog — no browser API does — so a `true` here means "the
    ## bytes were handed over", never "a file exists at a path".

proc mountedTemplate*(): ProjectTemplate =
  ## The project this page is editing, for anything that needs to ask
  ## afterwards.
  ##
  ## WAS A `var`, and the change is part of the defect's fix rather than
  ## tidying. As a `var` of a value type it was a private third copy of the
  ## template, written once by `enterTemplateEditMode` and read by nothing in
  ## Nim — so it could not observe an edit, and anything that later started
  ## reading it would have silently got the bundled bytes. It is now the one
  ## live project, which is the only value in the web arm that answers "what is
  ## the user editing".
  currentProject()

proc currentRendererEntryRequest*(): EntryRequest =
  ## The location, as `web_entry` wants it — read through the one
  ## implementation, `host/web_browser.currentEntryRequest`.
  ##
  ## This proc used to BE a second implementation, and the header above says
  ## why it was and why it no longer is. It survives as a named accessor rather
  ## than being deleted for its `else` branch: the module compiles on the C
  ## backend for unit tests, where there is no `window` and the true answer is
  ## the language-neutral root.
  when defined(js):
    currentEntryRequest()
  else:
    EntryRequest(origin: "", path: "/", fragment: "", query: "")

proc rendererDeploymentDescriptor*(): DeploymentDescriptor =
  ## The descriptor this page carries, or the empty one.
  ##
  ## An empty descriptor is a WORKING deployment, not a failure: it declares no
  ## language origins, `languageForOrigin` answers "", and every host behaves
  ## as the language-neutral root. That is the correct degradation — a
  ## single-domain deployment is what this product was until now.
  when defined(js):
    parseDeploymentDescriptor($jsDeploymentText())
  else:
    DeploymentDescriptor()

proc currentRendererHostLanguage*(): string =
  ## Which language this HOST's root means, if any. Rule 0 on the host axis.
  let request = currentRendererEntryRequest()
  languageForOrigin(rendererDeploymentDescriptor(), request.origin)

proc currentRendererEntry*(): EntryResolution =
  ## `LocalState()` for the same reason `web_browser.currentEntryResolution`
  ## passes one: the renderer has no store of its own, and an empty local state
  ## is the true statement about a build with no "most recent project". Rule
  ## 5's first row is what then applies.
  let request = currentRendererEntryRequest()
  resolveEntry(request, LocalState(),
               hostLanguage = languageForOrigin(rendererDeploymentDescriptor(),
                                                request.origin))


# ---------------------------------------------------------------------------
# The template, as an EDIT-MODE SESSION
#
# ## Why a payload and not a mount
#
# The first version of this module drew a Filesystem panel into
# `<section id="main">` with `mountIsoNimFilesystemPanel`, and what a visitor
# saw was a bare file tree: 46 readable characters, no topbar, no editor, no
# GoldenLayout. That was not a half-finished pane — it was a SECOND PATH into
# the product, claiming the job `onNoTrace` already does, and therefore getting
# none of what `onNoTrace` does on the way.
#
# CodeTracer already opens a folder in edit mode, and it enters through exactly
# one door: `CODETRACER::no-trace`. `index/startup.nim:249` sends it for
# `ct edit <path>`, `index/traces.nim:1173` sends it when the welcome screen
# opens a recent folder, and `ui_js.nim`'s `onNoTrace` handles both. That
# handler is the first screen: it assigns `data.config`, sets
# `data.ui.resolvedConfig`, calls `createUIComponents`, `loadTheme`,
# `tryInitLayout`, sets `data.ui.mode = EditMode`, refreshes the Filesystem
# panel, then runs `chooseInitialEditPath` over the project's filenames and
# `openTab`s the winner.
#
# So the web platform's job is not to reproduce any of that. It is to supply
# the payload — which is precisely the capability the facade is missing, since
# a statically hosted tab has no index process to send one. Every field below
# is the same field the desktop fills, from the bundled template instead of
# from a filesystem.
#
# ## The three fields that are not simply data
#
#   * `config` — `platform/config.defaultRendererConfig()`. See its header:
#     the desktop's index process fills this field from `default_config.yaml`
#     with `initShortcutMap`, and this fills it from the same file with the
#     same proc.
#
#   * `layout` — the desktop calls `loadEditLayoutConfig`, whose FALLBACK path
#     (no `default_edit_layout.json` yet, i.e. a first-ever launch) is
#     `sanitizeEditLayoutConfig(default_layout.json, ord(Content.EditorView),
#     editModeHiddenContentIds())`. A browser is always a first-ever launch —
#     it has no user layout directory and never will — so it takes that exact
#     branch, with the same two inputs, through the same
#     `index/layout_config_repair.sanitizeLayoutConfig`. That module documents
#     itself as dependency-free precisely so a non-Electron caller can use it.
#
#   * the source of the file edit mode opens — and this one is not a payload
#     field at all, which is why it is worth naming here. `onNoTrace` ends in
#     `data.openTab(initialEditPath)`, which reaches
#     `utils.asyncSend "tab-load"` — a QUESTION for the host, not a
#     notification. `installTemplateHost` answers it from the bundle with the
#     same `{argId, value}` message `index/config.sendTabInfo` sends.
#
#     The first attempt instead pre-filled `data.services.editor.open`, on the
#     strength of `EditorService.tabLoad`'s cache branch. It is worth recording
#     why that was wrong, because it looked right and it measured wrong:
#     `openTab` checks `open.hasKey(tabName)` FIRST and routes a hit to
#     `showTab`, which needs a `data.ui.editors[...]` entry that only
#     `openNewEditorView` creates. Seeding the cache therefore did not feed the
#     editor — it skipped the code that builds one, and the pane stayed empty.
#     Answering the question leaves every one of those steps where it is.
# ---------------------------------------------------------------------------

proc templateFilenames*(tmpl: ProjectTemplate): seq[string] =
  ## What the desktop's `loadFilenames` returns for the opened folder: the
  ## project's files, absolute, one per entry. `chooseInitialEditPath` scores
  ## this list, so its ORDER must not matter — and it does not, because that
  ## proc keeps a running maximum rather than a first match.
  for file in tmpl.files:
    result.add templateFilePath(tmpl, file.path)

proc noirStudioEditLayout*(): JsObject =
  ## The edit-mode layout: `mode_layouts.bundledLayoutForMode(EditMode)`.
  ##
  ## This proc used to `staticRead` `default_layout.json` itself and sanitise
  ## it with `editModeHiddenContentIds()`. It no longer decides anything — a
  ## mode's default layout is one function of the mode now, and it is shared
  ## with the desktop, which is what `Planned-Features/Noir-Studio.md` §1a.1
  ## requires: "no pane is invented for the web". A web-only opinion about
  ## where a pane lives would be exactly such an invention, and the way to not
  ## have one is to not have a second implementation.
  ##
  ## Kept as a name because `ui_js.nim` and the CI probes call it; it is now a
  ## spelling of the general rule rather than a second statement of it.
  cast[JsObject](bundledLayoutForMode(EditMode))

proc noirStudioDebugLayout*(): JsObject =
  ## The DEBUGGING layout, the same way — `bundledLayoutForMode(DebugMode)`.
  ##
  ## "Full surface, returnable" still holds, and the difference between the two
  ## modes is no longer only the SUPPRESSION. Debug mode also declares where
  ## TEST RESULTS and CONSTRAINTS live (`paneHomesForMode`), because the
  ## bundled tree gives them a column of their own for the EDITING surface §1a
  ## draws, and a replay inheriting that column was the defect this replaced.
  cast[JsObject](bundledLayoutForMode(DebugMode))

# `layoutComponents` MOVED to `ui/mode_layouts.nim` and is re-exported below.
# The walk is not the web's business: every mode switch that falls back to a
# mode's default installs a layout after startup and therefore has to construct
# the components it names, on both platforms.

proc templateFilesystem*(tmpl: ProjectTemplate): CodetracerFile =
  ## The project as the tree `index/files.loadFilesystem` returns.
  ##
  ## Shape-for-shape with that proc, because `ui/filesystem.legacyFileToVm`
  ## reads all of it: the artificial `source folders` root with `state.opened`,
  ## one child per opened folder, `original.path` as the row's identity,
  ## `index` / `parentIndices` as the coordinates `CODETRACER::update-path-
  ## content` addresses a node by, and the `path` property assigned onto the JS
  ## object at the end.
  ##
  ## DERIVED from `tmpl.files`, never written out beside it: a hand-built tree
  ## is a second statement of the project that no test can tell from the first
  ## until they disagree. `templateDirectories` likewise derives the folders,
  ## so the panel cannot show a folder the project has no file in.
  ##
  ## Folders precede loose files, which is what §1a's picture shows (`src`,
  ## then `Nargo.toml`) and what `readdir` order happens to give the desktop
  ## for this project. It is ordering, not identity — `chooseInitialEditPath`
  ## takes a maximum rather than a first match, so nothing downstream depends
  ## on it.
  let root = templateProjectRoot(tmpl)

  proc fileNode(path, text: string; index: int;
                parents: seq[int]): CodetracerFile =
    result = CodetracerFile(
      text: cstring(text), children: @[], index: index,
      parentIndices: parents,
      original: CodetracerFileData(text: cstring(text), path: cstring(path)))
    result.toJs.path = cstring(path)

  var project = CodetracerFile(
    text: cstring(tmpl.name), children: @[], state: js{opened: true},
    index: 0, parentIndices: @[],
    original: CodetracerFileData(text: cstring(tmpl.name), path: cstring(root)))
  project.toJs.path = cstring(root)

  var childIndex = 0
  for directory in templateDirectories(tmpl):
    var folder = CodetracerFile(
      text: cstring(directory), children: @[], state: js{opened: true},
      index: childIndex, parentIndices: @[0],
      original: CodetracerFileData(
        text: cstring(directory), path: cstring(root & "/" & directory)))
    folder.toJs.path = cstring(root & "/" & directory)
    var fileIndex = 0
    for file in tmpl.files:
      let prefix = directory & "/"
      if file.path.len > prefix.len and file.path[0 ..< prefix.len] == prefix and
         file.path.find('/', prefix.len) < 0:
        folder.children.add fileNode(
          templateFilePath(tmpl, file.path), file.path[prefix.len .. ^1],
          fileIndex, @[0, childIndex])
        fileIndex += 1
    project.children.add folder
    childIndex += 1

  for file in tmpl.files:
    if file.path.find('/') >= 0: continue
    project.children.add fileNode(
      templateFilePath(tmpl, file.path), file.path, childIndex, @[0])
    childIndex += 1

  result = CodetracerFile(
    text: cstring"source folders", children: @[project], state: js{opened: true},
    index: 0, parentIndices: @[],
    original: CodetracerFileData(text: cstring"source folders", path: cstring""))
  result.toJs.path = cstring""

proc templateTabInfo*(tmpl: ProjectTemplate; path: string): TabInfo =
  ## One document, in the shape `index/config.sendTabInfo` builds.
  ##
  ## Field for field with that proc's `TabInfo(...)` literal —
  ## `overlayExpanded: -1`, `highlightLine: -1`, `received: true`, `name` the
  ## basename and `path` the full one — because `renderer.onTabLoadReceived`
  ## casts what arrives to a `TabInfo` and `ui/editor.initMonacoForEditor`
  ## reads `source`, `lang` and `name` off it without asking where it came
  ## from.
  ##
  ## ## A file the template does not have gets a SENTENCE, not a blank editor
  ##
  ## §1b.3 step 6: "a plain statement of what was asked for and could not be
  ## found. Never a blank editor, never an error page." A shared link carrying
  ## `#f=src/typo.nr` reaches exactly here, and the two alternatives are both
  ## the failure that paragraph names — dropping the response hangs the tab on
  ## "Loading…" forever, and answering with an empty string is the blank
  ## editor itself.
  let slash = path.rfind('/')
  let base = if slash >= 0: path[slash + 1 .. ^1] else: path
  let index = templateFileFor(tmpl, path)
  let source =
    if index >= 0:
      cstring(tmpl.files[index].content)
    else:
      cstring("This project has no file named '" & path & "'.\n\n" &
              "It is the bundled '" & tmpl.name & "' template, and it " &
              "contains " & $tmpl.files.len & " files. A link that names a " &
              "file the template does not have opens this page instead.\n")
  TabInfo(
    overlayExpanded: -1,
    highlightLine: -1,
    viewLine: -1,
    location: types.Location(
      path: cstring(path), line: NO_LINE,
      highLevelPath: cstring(path), highLevelLine: NO_LINE,
      functionName: cstring""),
    source: source,
    sourceLines: source.split(jsNl),
    lastSyncedSource: source,
    received: true,
    loading: false,
    changed: false,
    name: cstring(base),
    path: cstring(path),
    lang: toLangFromFilename(cstring(path)))

proc installTemplateHost*() =
  ## Answer the one question edit mode asks that only a host can answer.
  ##
  ## `utils.asyncSend "tab-load"` registers a future keyed by the tab's path,
  ## sends the request and waits. On the desktop `index/files.open` reads the
  ## file and `index/config.sendTabInfo` replies on
  ## `CODETRACER::tab-load-received`; here the bundle already holds every byte,
  ## so the reply is composed without a read.
  ##
  ## `argId` is `location.highLevelPath` and must stay exactly that: it is the
  ## key `renderer.onTabLoadReceived` looks the pending future up by
  ## (`data.network.futures["tab-load"][response.argId]`), so a spelling that
  ## differs by one character resolves nothing and hangs the tab — the failure
  ## `sendTabInfo`'s own header warns about from the other side.
  ##
  ## Registered BEFORE the `no-trace` delivery, because `onNoTrace` ends by
  ## opening the initial tab: a responder installed afterwards would be
  ## installed after the question it exists to answer.
  ##
  ## ## It answers from `currentProject()`, NOT from the captured `tmpl`
  ##
  ## The parameter is still taken — it is what `enterTemplateEditMode` has in
  ## hand, and it seeds the store — but the responder must read the LIVE
  ## project, and the difference is a real defect rather than a style
  ## preference. `ProjectTemplate` is an `object`: a captured `tmpl` is a
  ## private copy frozen at install time. A visitor who edits `src/utils.nr`,
  ## closes the tab and reopens it would have been served the bundled bytes
  ## back — their edit still in the store, still in what Build compiles, and
  ## silently absent from the editor that reopened it. Reading the accessor
  ## keeps the tab, the build and the store one value.
  ##
  ## THE PARAMETER IS GONE, not merely discarded. `discard tmpl` said "do not
  ## capture this" to a reader who was already reading; a signature with
  ## nothing to capture says it to one who is not. The defect recurred once in
  ## this very file despite the paragraph above, which is the measurement that
  ## a comment was not enough.
  data.ipc.respond(cstring"CODETRACER::tab-load",
    proc(sender: js, payload: JsObject) =
      let location = cast[types.Location](payload["location"])
      let requested = location.highLevelPath
      data.ipc.deliver(cstring"CODETRACER::tab-load-received", js{
        argId: requested,
        value: templateTabInfo(currentProject(), $requested)
      }))

proc installProjectSaveHost*() =
  ## Answer `CODETRACER::save-file` — THE MESSAGE WITH NO HOST.
  ##
  ## This is `installTemplateHost`'s pattern applied to the other half of the
  ## defect, and the renderer needs no change at all because its half was
  ## already complete and already correct:
  ##
  ##   * `default_config.yaml` binds `ctrl+s`, and `ui_js.update` calls
  ##     `data.saveFiles(activePath)`.
  ##   * `renderer.saveFiles` walks `saveTargets`, and
  ##     `renderer.dispatchSaveEffect` reads the buffer with
  ##     `tab.monacoEditor.getValue()` and sends
  ##     `CODETRACER::save-file` as `{name, raw, saveAs}`.
  ##   * `ui_js.configureIPC` has subscribed `saved-file` and
  ##     `save-file-error` all along (`onSavedFile`, `onSaveFileError`).
  ##
  ## Every one of those ran on the web build. The chain ended at
  ## `newWebIpc.send`, which found no responder and logged *"no host for
  ## CODETRACER::save-file"*. So this proc is the twenty lines the whole path
  ## was missing, and the reply channels are the desktop's own:
  ## `index/files.nim:293` sends `CODETRACER::saved-file` as `js{name}` and
  ## `index/files.nim:296` sends `CODETRACER::save-file-error` as
  ## `js{name, error}`. Matching those spellings is what lets
  ## `onSavedFile` clear `tab.changed` without knowing which platform answered.
  ##
  ## `save-untitled` is answered SEPARATELY, by `installUntitledSaveHost`.
  ##
  ## It used to be answered by nothing, on the stated reasoning that
  ## "`rreSaveUntitled` is unreachable from a project whose every tab has a
  ## path". That was true and issue #735 made it false: "New file" is a live
  ## start option on this arm now, so a browser tab can hold an untitled buffer
  ## and `ctrl+s` over it reaches `CODETRACER::save-untitled`. Left unanswered
  ## that is a blank failure over the user's own typing, which is the one
  ## outcome `Noir-Studio.md` §4.2 rules out outright.
  ##
  ## The two hosts are separate procs because their destinations are different
  ## in kind: this one writes into the OPFS working copy of an OPEN PROJECT,
  ## and that one has no project to write into and hands the bytes to the user
  ## instead. Merging them would need a branch on "is there a project" inside a
  ## responder, which is the shape that made `projectRelative` return "" and
  ## report a path as "outside the open project" when the truth was that there
  ## was no project.
  data.ipc.respond(cstring"CODETRACER::save-file",
    proc(sender: js, payload: JsObject) =
      let name = cast[cstring](payload["name"])
      let raw = cast[cstring](payload["raw"])
      # THE SENDER'S ACCOUNT OF WHETHER ITS BUFFER WAS EVER EDITED, carried
      # across the message rather than re-derived here — the host has no editor
      # to ask. Absent (`-1`) when the sender did not supply it, which
      # `classifyWrite` treats as unproven: a save that cannot say where its
      # emptiness came from may not empty a stored file. See
      # `file_conflicts.BufferProvenance`.
      var edits = -1
      let rawEdits = payload["bufferEdits"]
      if not rawEdits.isNil:
        edits = rawEdits.to(int)
      let relative = projectRelative(currentProject(), $name)
      if relative.len == 0:
        data.ipc.deliver(cstring"CODETRACER::save-file-error", js{
          name: name,
          error: cstring("'" & $name & "' is outside the open project")
        })
        return
      saveProjectFile(relative, $raw, proc(ok: bool; error: string) =
        if ok:
          data.ipc.deliver(cstring"CODETRACER::saved-file", js{name: name})
        else:
          data.ipc.deliver(cstring"CODETRACER::save-file-error", js{
            name: name, error: cstring(error)
          }),
        editsSinceLoad = edits))

# THE PARAGRAPH THAT USED TO BE HERE IS GONE, and its removal is the point
# rather than a tidy-up.
#
# `webTestRunAbsence` was a const saying, in nine lines, that this build could
# not run the tests: a browser has no `nargo` and no subprocess, and the Noir
# wasm worker implements exactly two operations, `compile` and `trace`. It was
# true when it was written and it named its own conditions precisely enough to
# be checkable. All three have since changed:
#
#   * `noir_wasm.wasm` exports `nv_test_vfs` beside `nv_compile_vfs`
#     (`compiler/wasm/src/test_vfs.rs` in the pinned `noir` fork);
#   * `wasm_worker_browser.js` routes the `test` subcommand to it;
#   * the verdicts come from `nargo::ops::run_test` itself, so
#     `#[test(should_fail)]` inverts the way `nargo test` inverts it.
#
# What replaces it is not a shorter paragraph. It is `web_noir_build.
# noirTestRunAbsence()`, which asks THIS deployment whether it can run tests
# and answers "" when it can — and the ▶ the Test Results pane now renders.
# Leaving the prose behind would have taught a visitor the product is less
# capable than it is, which is the mirror image of an affordance that does
# nothing.

proc templateTestCatalog*(tmpl: ProjectTemplate): TestCatalog =
  ## Which tests the bundled project has, parsed from its own sources by the
  ## parser `ct test`'s Noir provider uses.
  ##
  ## Not a second discovery implementation and not a hand-written list: the
  ## renderer calls `noir_test_syntax.noirCatalogFromSources`, which
  ## `frameworks/noir_nargo.nim` also calls after reading files off a disk.
  ## `ci/test/noir-template-toolchain.sh` runs the real `nargo test` over this
  ## same template and requires the selector SETS to be equal, so "the pane
  ## lists the tests the runner runs" is measured rather than asserted.
  var sources: seq[NoirSourceFile] = @[]
  for file in tmpl.files:
    sources.add NoirSourceFile(path: file.path, content: file.content)
  noirCatalogFromSources(sources)

proc templateConstraintReport*(tmpl: ProjectTemplate): ConstraintReport =
  ## What the bundled circuit costs.
  ##
  ## Parsed from `noir_template.noirTemplateNargoInfoJson` with the same
  ## `parseNargoInfoJson` the desktop uses on live `nargo info` output — one
  ## parser, one shape, two sources. The counts are a pure function of sources
  ## that are themselves a compile-time constant, and
  ## `ci/test/noir-template-toolchain.sh` recompiles the template with the wasm
  ## module the deploy ships and fails if the ACIR total has drifted from it —
  ## so the headline number is a measurement that travels rather than a cached
  ## answer. The unconstrained counts are NOT covered by that comparison; see
  ## `noirTemplateNargoInfoJson`'s docstring for what the gate does and does not
  ## establish.
  ## THE COUNTS COME OFF `tmpl`, not off a module constant, and that changed
  ## because a second template arrived. This proc took a `tmpl`, checked it for
  ## files and then reported `noirTemplateNargoInfoJson` — the hello-world's
  ## numbers — whatever project was open. With one template that is
  ## indistinguishable from correct; with two it is a pane reporting 17 ACIR
  ## opcodes over `/noir/demo`'s circuit, under a provenance string promising
  ## the figure was measured. See `ProjectTemplate.nargoInfoJson`.
  if not tmpl.hasFiles:
    return absentReport("No project is open.")
  if tmpl.nargoInfoJson.len == 0:
    return absentReport("This project does not ship a measured constraint count.")
  parseNargoInfoJson(tmpl.nargoInfoJson, tmpl.constraintProvenance)

proc installTemplatePaneHost*() =
  ## Answer `CODETRACER::ns9-panes` for the bundled template.
  ##
  ## The web platform's half of the one message NS9's panes are fed by; the
  ## Electron index's half is `index/ns9_panes.nim`. `onNoTrace` sends the
  ## request once edit mode's layout exists, and both hosts reply on the same
  ## two channels, so the renderer's handlers cannot tell them apart.
  ##
  ## Registered BEFORE the `no-trace` delivery, because that delivery is what
  ## ends up sending the request — a responder installed afterwards would be
  ## installed after the question.
  ##
  ## IT DOES NOT CAPTURE `tmpl`, and that is the whole reason the message can be
  ## asked twice. `installNoirBuildCommands` had exactly this defect and its
  ## comment records the fix: a copy of a value type, frozen at install time,
  ## read by every later call. A responder that closed over `tmpl` would answer
  ## the BUNDLED sources for the rest of the session — so a user who wrote a
  ## new `#[test]` and saved would get the original catalog back, and the pane
  ## and the gutter would both quietly refuse to notice what they had just
  ## written. `currentProject()` is what the editor last saved.
  ##
  ## IT TAKES NO PROJECT, exactly as `installTemplateHost` takes none — see
  ## that proc's header, which was written about this same defect and which
  ## this proc, 140 lines below it in the same file, captured anyway.
  ##
  ## The constraint half still answers about the BUNDLED template's numbers,
  ## and that is deliberate rather than a leftover capture:
  ## `noirTemplateNargoInfoJson` is a compile-time constant measured by a real
  ## `nargo info` against those sources, and there is no `nargo info` in the
  ## wasm module to re-derive it from edited ones. It reads `currentProject()`
  ## only to decide whether a project is open at all. The constraint pane's
  ## provenance string is what tells a reader which sources the counts are
  ## about, and it says so on the pane rather than only here.
  data.ipc.respond(cstring"CODETRACER::ns9-panes",
    proc(sender: js, payload: JsObject) =
      data.ipc.deliver(cstring"CODETRACER::ns9-panes-catalog", js{
        catalog: cstring(pretty(templateTestCatalog(currentProject()).toJson())),
        # ASKED, NOT ASSERTED. "" on a deployment that placed the Noir
        # compiler module, and `degradedBehaviour`'s own sentence on one that
        # did not — see `noirTestRunAbsence`.
        absence: cstring(noirTestRunAbsence())
      })
      # ALL THREE FIELDS NOW COME FROM ONE PROJECT. Two of them used to be
      # module constants while `absence` was derived from `currentProject()`,
      # so a template without counts produced an absence string sitting beside
      # another project's numbers. Reading the open project once removes the
      # question of which of the three is about which template.
      let openProject = currentProject()
      let report = templateConstraintReport(openProject)
      data.ipc.deliver(cstring"CODETRACER::ns9-panes-constraints", js{
        info: cstring(openProject.nargoInfoJson),
        provenance: cstring(openProject.constraintProvenance),
        absence: cstring(report.absence)
      }))

proc templateNoTracePayload*(tmpl: ProjectTemplate; layout: JsObject): JsObject =
  ## The `CODETRACER::no-trace` message, field for field with
  ## `index/startup.nim:249` and `index/traces.nim:1173`.
  ##
  ## `startOptions.edit = true` is what makes this EDIT mode rather than an
  ## empty session, and `onNoTrace` reads it twice: once to set
  ## `startOptions.folder`, and once as `chooseInitialEditPath`'s third
  ## argument — which returns "" when it is false, so a payload that forgot it
  ## would open the layout with no file in the editor.
  ##
  ## `welcomeScreen = false` matters for a different reason and is easy to miss:
  ## `ui/layout.initLayout` returns EARLY, before GoldenLayout is constructed,
  ## when `data.startOptions.welcomeScreen and data.trace.isNil` — and
  ## `data.trace` IS nil here, because an edit session has no recording. With
  ## the flag left true the layout would silently not exist and every pane with
  ## it.
  ##
  ## `functions` and `save.files` are empty, exactly as the desktop leaves them
  ## for a folder open: `index/files.getSave` returns `Save(project: Project(),
  ## files: @[], id: -1)` unconditionally, and `traces.nim` passes
  ## `var functions: seq[Function] = @[]` with a `TODO` beside it. So these are
  ## not web stubs — they are the values this path has on both platforms.
  var startOptions = StartOptions(
    edit: true,
    welcomeScreen: false,
    screen: false,
    loading: false,
    inTest: false,
    record: false,
    isInstalled: true,
    # EMPTY, and this is the difference between a first screen and a blank
    # one. `onNoTrace` passes `startOptions.name` to `chooseInitialEditPath` as
    # its `requestedPath`, and that proc returns a non-empty `requestedPath`
    # UNCHANGED — the heuristic never runs. With the project root here, edit
    # mode opened `/hello_noir` as though the FOLDER were a source file:
    # measured, `editor: openTab: /hello_noir` followed by a `tab-load` for a
    # directory.
    #
    # `index/traces.nim:1156` sets `data.startOptions.name = cstring""` for
    # exactly this reason when the welcome screen opens a folder, and keeps
    # the path in `folder`. This is that line, and the split of meaning
    # between the two fields is the whole of it: `name` is the file the user
    # named, `folder` is the project they opened.
    name: cstring"",
    folder: cstring(templateProjectRoot(tmpl)),
    app: cstring"",
    recordingID: cstring"")

  js{
    path: cstring(templateProjectRoot(tmpl)),
    lang: LangNoir,
    home: cstring"",
    # PASSED IN, not computed here, so the layout the caller checked for nil is
    # the layout that travels. Building it twice would make the guard a
    # statement about a different value than the one the payload carries — the
    # shape of bug that hides until the two disagree.
    layout: layout,
    helpers: JsAssoc[cstring, Helper]{},
    startOptions: startOptions,
    config: defaultRendererConfig(),
    # Nim `string`s, NOT `cstring`s, and the difference is not cosmetic here.
    # `onNoTrace` declares this field `seq[string]` and hands it to
    # `chooseInitialEditPath`; a `cstring` arriving where the compiler was
    # promised a `string` survives every string operation in that proc and
    # then mangles on the way out — measured, the chosen path came back as
    # `%0/%0h%0e%0l%0l%0o%0_%0n%0o%0i%0r%0/...`, one `%0` per character, and
    # edit mode opened a tab named that. The mangling is downstream: the
    # scoring silently degraded first (every candidate scored equal, so the
    # FIRST file won rather than the best one) which is how `Nargo.toml`
    # became the initial tab instead of `src/main.nr`.
    filenames: templateFilenames(tmpl),
    filesystem: templateFilesystem(tmpl),
    functions: newSeq[Function](),
    save: Save(project: Project(), files: @[], id: -1)
  }

proc installUntitledSaveHost*()
  ## Defined below, beside the rest of the #735 "New file" path; forward-declared
  ## here because `enterTemplateEditMode` installs it too. The menu's New File
  ## action (`ui_js.nim`'s `newTab`) is reachable from inside an open project,
  ## so an untitled buffer — and therefore `CODETRACER::save-untitled` — is not
  ## exclusive to the welcome screen's route.

proc enterTemplateEditMode*(tmpl: ProjectTemplate): bool =
  ## Open the bundled template in edit mode. Returns whether the message was
  ## delivered, so the caller reports a refusal rather than assuming — the
  ## convention `mountWebWelcomeScreen` set and mutation arm B of
  ## `ci/test/web-renderer-mounts.sh` depends on.
  ##
  ## `deliver`, not `send`. `ui_js.newWebIpc`'s third method exists for this:
  ## it runs the handlers `configureIPC` registered, locally, on the same path
  ## a host's message takes. So `onNoTrace` cannot tell this apart from
  ## `index/traces.nim` opening a recent folder, which is the entire point —
  ## one door into edit mode, not two.
  if not tmpl.hasFiles:
    return false
  if data.ipc.isNil or data.ipc.isUndefined:
    return false
  # THE VISITOR'S OWN EDIT LAYOUT, IF THIS BROWSER HAS ONE.
  #
  # This used to be `noirStudioEditLayout()` unconditionally — the bundled
  # default, every time — which made a reload a first-ever launch no matter how
  # long the visitor had been arranging their workspace.
  # `Mode-Transitions.md` §4.1 is explicit that a mode's layout comes from the
  # mode's store when one exists and "never rebuilds from the bundled default
  # when a user arrangement exists", and §4.3 exists precisely so a RELOAD
  # keeps it.
  #
  # MEASURED before this line consulted the store: a drag that took the FILES
  # stack from 304px to 464px came back at 317px after a reload, and the stored
  # edit layout — which was correct, and 3071 bytes — was overwritten with the
  # default's 3041 the moment the boot layout was saved back.
  #
  # `resolveLayoutForMode` is the same accessor a mode SWITCH uses, so the
  # layout a reload lands on and the layout a switch lands on cannot drift.
  # It is total: the worst case is this mode's default, which is what this
  # line used to be.
  let resolution = mode_layouts.resolveLayoutForMode(data, EditMode)
  let layout = cast[JsObject](resolution.config)
  if layout.isNil:
    # The bundled layout did not parse. Refusing is the honest answer: with no
    # layout `onNoTrace` would reach `tryInitLayout` with a nil config, mount
    # an empty GoldenLayout and leave a visitor looking at a window with no
    # panes and no explanation.
    return false

  # SEED THE LIVE PROJECT, unless something already restored one.
  #
  # `ui_js.startWebArm` calls `web_project_persistence.prepareProject` before
  # the renderer mounts, and that is what puts the STORE's copy — a returning
  # visitor's edits — into `currentProject()`. When it ran, it wins, and the
  # parameter is the bundle it was seeded from. When it did not (a unit test, a
  # refused boot), the parameter is the whole truth and becomes the session's
  # working tree. Either way there is exactly one value from here on, and
  # `mountedTemplate` — a third copy nothing ever read — is gone.
  if not hasLiveProject():
    setCurrentProject(tmpl)
  let effective = currentProject()

  installTemplateHost()
  installProjectSaveHost()
  installTemplatePaneHost()
  # The replay host, registered here for the reason `installTemplateHost`'s
  # own header gives about itself: before the `no-trace` delivery, so it
  # exists before anything can ask. Nothing asks until a Run has produced a
  # trace, so this only makes the tab ABLE to open a session.
  installReplayHost()
  installUntitledSaveHost()
  discard data.ipc.deliver(cstring"CODETRACER::no-trace",
                           templateNoTracePayload(effective, layout))
  true

# ---------------------------------------------------------------------------
# ISSUE #735 — "New file" in a browser tab
# ---------------------------------------------------------------------------
#
# The welcome screen's other five start options need something this page does
# not have: a folder on the user's disk, a trace file, a recorder, an Electron
# main process. "New file" needs none of them — an untitled buffer is a string
# in the renderer — which is why it is the one start option `WebHandledStart
# Options` contains, and why issue #735's reporter asked for it *"especially on
# the web build, where Open folder does not work"*.
#
# It goes through the SAME DOOR as everything else: a `CODETRACER::no-trace`
# delivery. `enterTemplateEditMode` above uses it for the bundled project and
# `index/traces.onNewFile` uses it on the desktop for exactly this feature, so
# `ui_js.onNoTrace` — which is the proc that turns the message into Edit mode
# and then opens the untitled buffer — cannot tell the three apart. One door,
# not three.

proc emptyProjectFilesystem*(): CodetracerFile =
  ## The filesystem tree for a session with NO project: the artificial
  ## "source folders" root, with nothing under it.
  ##
  ## Shape-for-shape with `index/files.loadFilesystem(@[], …)`, which is the
  ## value the desktop's own `onNewFile` sends — the same proc that serves an
  ## open folder, called with no folders. `ui/filesystem.legacyFileToVm` reads
  ## `text`, `state`, `original` and the `path` property off the root whether or
  ## not it has children, so an empty tree has to be this and not nil: a nil
  ## filesystem reaches the panel as `undefined` and the Files pane renders
  ## nothing at all rather than an empty project.
  result = CodetracerFile(
    text: cstring"source folders", children: @[], state: js{opened: true},
    index: 0, parentIndices: @[],
    original: CodetracerFileData(text: cstring"source folders", path: cstring""))
  result.toJs.path = cstring""

proc untitledDownloadName*(bufferName: string): string =
  ## The filename a browser download gets for an untitled buffer.
  ##
  ## `renderer.openNewTab` names its buffers `#untitled{N}`, and the leading
  ## `#` is a marker for "this tab has no path" rather than part of a name
  ## anyone wants on their disk — a downloaded `#untitled1` is also a filename
  ## every shell needs quoting for. The extension is `.txt` because the buffer
  ## has no language: `fromPath("#untitled1")` is `LangUnknown`, and guessing
  ## one from content would be a guess shown as a fact.
  ##
  ## Total, and deliberately so — a name this does not recognise is returned
  ## with only the `#` stripped, because refusing to name a download is
  ## refusing to save the user's work.
  var name = bufferName
  if name.len > 0 and name[0] == '#':
    name = name[1 .. ^1]
  if name.len == 0:
    name = "untitled"
  if name.find('.') < 0:
    name &= ".txt"
  name

proc installUntitledSaveHost*() =
  ## Answer `CODETRACER::save-untitled` — see `installProjectSaveHost`'s header
  ## for why this is now a message that reaches a browser tab at all.
  ##
  ## The reply channels are the desktop's own (`index/files.onSaveUntitled`
  ## sends `CODETRACER::saved-file` as `js{name}` and `CODETRACER::save-file-
  ## error` as `js{name, error}`), and the `name` echoed back is the BUFFER's,
  ## not the download's: `ui_js.onSavedFile` looks the tab up by it, and a tab
  ## keyed `#untitled1` that is answered `untitled1.txt` stays dirty for ever.
  ## Renaming the tab to its saved destination is a renderer-side change this
  ## milestone did not make, and it is the same gap the desktop has.
  data.ipc.respond(cstring"CODETRACER::save-untitled",
    proc(sender: js, payload: JsObject) =
      let name = cast[cstring](payload["name"])
      let raw = cast[cstring](payload["raw"])
      if jsDownloadTextFile(cstring(untitledDownloadName($name)), raw):
        data.ipc.deliver(cstring"CODETRACER::saved-file", js{name: name})
      else:
        data.ipc.deliver(cstring"CODETRACER::save-file-error", js{
          name: name,
          error: cstring("this browser refused the download, so '" & $name &
                         "' was not saved")
        }))

proc newFileNoTracePayload*(layout: JsObject): JsObject =
  ## The `CODETRACER::no-trace` message for a session with no project.
  ##
  ## `templateNoTracePayload`'s field list, with the project taken out. The two
  ## are deliberately separate rather than one proc with an `Option[Project
  ## Template]`: every difference between them is a field whose EMPTY value is
  ## load-bearing, and reading them side by side is what makes that visible.
  ##
  ## - `folder: ""` is what `ui_js.onNoTrace` branches on to decide this
  ##   session gets an untitled buffer. `templateNoTracePayload` sends the
  ##   project root there; `index/traces.initEditMode` sends the opened folder.
  ##   Nothing else in the product reaches edit mode with no folder at all — see
  ##   that branch's comment for what guarantees it — so the branch is this
  ##   feature's and only this feature's.
  ## - `name: ""` for `templateNoTracePayload`'s reason: `onNoTrace` hands it to
  ##   `chooseInitialEditPath` as the requested path, and a non-empty value is
  ##   returned UNCHANGED and opened as a tab.
  ## - `welcomeScreen: false` because `ui/layout.initLayout` returns before
  ##   GoldenLayout is constructed while it is true and `data.trace` is nil,
  ##   which is exactly the state this page is in.
  var startOptions = StartOptions(
    edit: true,
    welcomeScreen: false,
    screen: false,
    loading: false,
    inTest: false,
    record: false,
    isInstalled: true,
    name: cstring"",
    folder: cstring"",
    app: cstring"",
    recordingID: cstring"")

  js{
    path: cstring"",
    lang: LangUnknown,
    home: cstring"",
    layout: layout,
    helpers: JsAssoc[cstring, Helper]{},
    startOptions: startOptions,
    config: defaultRendererConfig(),
    filenames: newSeq[string](),
    filesystem: emptyProjectFilesystem(),
    functions: newSeq[Function](),
    save: Save(project: Project(), files: @[], id: -1)
  }

proc enterNewFileEditMode*(): bool =
  ## Open CodeTracer in Edit mode on a single untitled buffer, with no project.
  ##
  ## Returns whether the message was delivered, by `enterTemplateEditMode`'s
  ## convention: the caller reports a refusal rather than assuming.
  ##
  ## No `installTemplateHost` here, and that is not an omission. That host
  ## answers `tab-load` out of the bundled project, and there is no project; the
  ## untitled buffer is created by `renderer.openNewTab`, which builds its
  ## `TabInfo` itself and never asks a host for source. A `tab-load` responder
  ## installed here would be a host for a question nothing on this path asks.
  if data.ipc.isNil or data.ipc.isUndefined:
    return false
  let resolution = mode_layouts.resolveLayoutForMode(data, EditMode)
  let layout = cast[JsObject](resolution.config)
  if layout.isNil:
    # `enterTemplateEditMode`'s reason, unchanged: with no layout `onNoTrace`
    # mounts an empty GoldenLayout and the visitor sees a window with no panes
    # and nothing saying why.
    return false
  installUntitledSaveHost()
  discard data.ipc.deliver(cstring"CODETRACER::no-trace",
                           newFileNoTracePayload(layout))
  true
