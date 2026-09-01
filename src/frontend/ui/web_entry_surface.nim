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
## ## Why this reads the location again rather than taking it from `boot()`
##
## `boot()` now resolves the entry too, and reports it on the boot line. It
## cannot HAND the resolution over, and the reason is structural rather than
## tidiness: `web.js` and `ui.js` are separately compiled Nim programs, each
## wrapped in its own IIFE by `ci/test/web-bundle-assets.sh`. That scoping is
## load-bearing — unwrapping it is mutation arm C of the mount gate, and it
## breaks the loop arm because `ui.js` redefines 196 of `web.js`'s functions —
## so there is no shared value for them to share. And `boot()` is `async`,
## while `startWebRenderer()` runs at `ui.js` module init: even a DOM handoff
## would be a race the renderer loses on every load.
##
## What is NOT duplicated is the part that matters. `classifyPath` and
## `resolveEntry` are imported from `platform/web_entry`, so both arms reach
## the same verdict from the same code; only the three-line read of
## `window.location` appears twice. `web_entry.classifyPath`'s own header names
## the hazard precisely — "two implementations of *which prefixes exist* is how
## a form reaches the SPA in the code and 404s at the CDN" — and that is the
## classification, which has exactly one implementation here.
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
from ../index/layout_config_repair import sanitizeLayoutConfig
from ../edit_mode import chooseInitialEditPath
from ../../ct_test/contracts import TestCatalog
from ../../ct_test/frameworks/noir_test_syntax import
  NoirSourceFile, noirCatalogFromSources
from ../../common/noir_constraints import
  ConstraintReport, parseNargoInfoJson, absentReport
from ../../ct_test/contracts import toJson

when defined(js):
  proc jsEntryPath(): cstring {.importjs: """
(function () {
  try {
    if (typeof window !== 'undefined' && window.location) {
      return String(window.location.pathname || '/');
    }
  } catch (e) {}
  return '/';
})()""".}

  proc jsEntryOrigin(): cstring {.importjs: """
(function () {
  try {
    if (typeof window !== 'undefined' && window.location) {
      return String(window.location.origin || '');
    }
  } catch (e) {}
  return '';
})()""".}

  proc jsEntryHash(): cstring {.importjs: """
(function () {
  try {
    if (typeof window !== 'undefined' && window.location) {
      return String(window.location.hash || '');
    }
  } catch (e) {}
  return '';
})()""".}
    ## Returns the hash RAW, leading separator included, and the separator is
    ## stripped in Nim below rather than here.
    ##
    ## Not a style choice. `importjs` reads `#` as a parameter placeholder, so
    ## a pattern containing the literal `'#'` this function would need to
    ## compare against fails the build with
    ##
    ##     Error: wrong importcpp pattern; expected parameter at position 1
    ##
    ## — the same trap `web_main.nim`'s `jsReport` documents from the other
    ## side. `host/web_browser.currentEntryRequest` strips it in Nim for this
    ## reason too, so both arms now do the identical thing.

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

  proc jsEntrySearch(): cstring {.importjs: """
(function () {
  try {
    if (typeof window !== 'undefined' && window.location) {
      return String(window.location.search || '');
    }
  } catch (e) {}
  return '';
})()""".}

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

var mountedTemplate*: ProjectTemplate
  ## The template this page entered edit mode on, for anything that needs to
  ## ask afterwards. Written only by `enterTemplateEditMode`.

proc currentRendererEntryRequest*(): EntryRequest =
  ## The renderer arm's read of the location. See the header for why there are
  ## two of these and why only the read is duplicated.
  when defined(js):
    var hash = $jsEntryHash()
    if hash.len > 0 and hash[0] == '#': hash = hash[1 .. ^1]
    var search = $jsEntrySearch()
    if search.len > 0 and search[0] == '?': search = search[1 .. ^1]
    EntryRequest(origin: $jsEntryOrigin(), path: $jsEntryPath(),
                 fragment: hash, query: search)
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
  ## It names no real filesystem and is not meant to: nothing in this build
  ## reads or writes it. It is the identity a tab, a tree row and a breakpoint
  ## table are keyed by, which is all a path is to the renderer.
  "/" & tmpl.name

proc templateFilePath*(tmpl: ProjectTemplate; path: string): string =
  templateProjectRoot(tmpl) & "/" & path

proc templateFilenames*(tmpl: ProjectTemplate): seq[string] =
  ## What the desktop's `loadFilenames` returns for the opened folder: the
  ## project's files, absolute, one per entry. `chooseInitialEditPath` scores
  ## this list, so its ORDER must not matter — and it does not, because that
  ## proc keeps a running maximum rather than a first match.
  for file in tmpl.files:
    result.add templateFilePath(tmpl, file.path)

const bundledLayoutJson = staticRead("../../config/default_layout.json")
  ## The same `src/config/default_layout.json` that `ui/layout.nim:733` and
  ## `index/config.nim:698` already `staticRead`. A third read of ONE file is
  ## not a third copy of the layout — deleting the file breaks all three
  ## builds at compile time, which is the property that matters.

proc parseLayoutJsonOrNil(raw: cstring): JsObject {.importjs:
  """(function(raw) {
    try { return JSON.parse(raw); } catch (error) { return null; }
  })(#)""".}
  ## `ui/layout.nim:735`'s `tryParseLayoutJson`, which is private to that
  ## module. A `JSON.parse` that throws at renderer module-init would take the
  ## whole bundle down before anything mounted — the exact failure mode
  ## `ui_js.nim`'s web arm was written against.

proc noirStudioEditLayout*(): JsObject =
  ## The edit-mode layout, produced the way a first-ever desktop launch
  ## produces it. See the block comment above for why this is the same branch
  ## and not a web-specific layout.
  let bundled = parseLayoutJsonOrNil(cstring(bundledLayoutJson))
  if bundled.isNil:
    return nil
  sanitizeLayoutConfig(bundled, ord(Content.EditorView),
                       editModeHiddenContentIds())

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

proc templateFileFor*(tmpl: ProjectTemplate; path: string): int =
  ## The index in `tmpl.files` of the file a tab-load names, or `-1`.
  ##
  ## The renderer asks by ABSOLUTE path (`/hello_noir/src/main.nr`) because
  ## that is what it opened; the template stores project-relative paths. One
  ## prefix strip, in one place, so `templateProjectRoot` stays the only thing
  ## that knows the project's root.
  let prefix = templateProjectRoot(tmpl) & "/"
  if path.len <= prefix.len or path[0 ..< prefix.len] != prefix:
    return -1
  let relative = path[prefix.len .. ^1]
  for index, file in tmpl.files:
    if file.path == relative:
      return index
  -1

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

proc installTemplateHost*(tmpl: ProjectTemplate) =
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
  data.ipc.respond(cstring"CODETRACER::tab-load",
    proc(sender: js, payload: JsObject) =
      let location = cast[types.Location](payload["location"])
      let requested = location.highLevelPath
      data.ipc.deliver(cstring"CODETRACER::tab-load-received", js{
        argId: requested,
        value: templateTabInfo(tmpl, $requested)
      }))

const webTestRunAbsence* =
  "This build cannot run the tests. A browser has no `nargo` and no " &
  "subprocess, and the Noir wasm worker implements exactly two operations — " &
  "`compile` and `trace`. Running these needs a test operation in the wasm " &
  "module and a branch for it in the worker; neither exists yet. The tests " &
  "listed above are the ones `nargo test` would run: the selectors are " &
  "produced by the same parser the `ct test` provider uses, and " &
  "`ci/test/noir-template-toolchain.sh` compares them against nargo's own " &
  "names on every run."
  ## Why the Run column is not offered here, said once, where the pane can
  ## show it. A pane that lists five tests beside a button that does nothing
  ## is worse than one that says why — and "not wired up yet" would be untrue:
  ## the operation does not exist to wire.

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
  ## `ci/test/noir-template-toolchain.sh` re-runs `nargo info` and fails on any
  ## drift, so this is a measurement that travels rather than a cached answer.
  if not tmpl.hasFiles:
    return absentReport("No project is open.")
  parseNargoInfoJson(noirTemplateNargoInfoJson,
                     noirTemplateConstraintProvenance)

proc installTemplatePaneHost*(tmpl: ProjectTemplate) =
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
  data.ipc.respond(cstring"CODETRACER::ns9-panes",
    proc(sender: js, payload: JsObject) =
      data.ipc.deliver(cstring"CODETRACER::ns9-panes-catalog", js{
        catalog: cstring(pretty(templateTestCatalog(tmpl).toJson())),
        absence: cstring(webTestRunAbsence)
      })
      let report = templateConstraintReport(tmpl)
      data.ipc.deliver(cstring"CODETRACER::ns9-panes-constraints", js{
        info: cstring(noirTemplateNargoInfoJson),
        provenance: cstring(noirTemplateConstraintProvenance),
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
  let layout = noirStudioEditLayout()
  if layout.isNil:
    # The bundled layout did not parse. Refusing is the honest answer: with no
    # layout `onNoTrace` would reach `tryInitLayout` with a nil config, mount
    # an empty GoldenLayout and leave a visitor looking at a window with no
    # panes and no explanation.
    return false

  installTemplateHost(tmpl)
  installTemplatePaneHost(tmpl)
  mountedTemplate = tmpl
  discard data.ipc.deliver(cstring"CODETRACER::no-trace",
                           templateNoTracePayload(tmpl, layout))
  true
