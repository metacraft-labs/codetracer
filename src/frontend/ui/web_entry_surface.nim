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
## ## What this deliberately does not claim
##
## §1a's first screen is Filesystem, Editor, Test Results and Constraints in a
## GoldenLayout, and that is **NS9**, whose own milestone entry is `planned`
## and depends on NS4, NS6 and NS8. This mounts the panes that exist today over
## the template's real files. `mountWebWelcomeScreen`'s header already drew
## this line for the welcome screen and it is drawn again here: what closes is
## the gap BELOW NS9 — the route is honoured, and the template is what `/noir`
## opens — not NS9 itself. The renderer line says `surface=noir-template` and
## names the file count, so nobody reading a log has to guess which of the two
## was achieved.

import
  std/[ strutils ],
  ui_imports

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types import
  FilesystemEntryNode, FilesystemDiffClass, fdcNone
from ../viewmodel/viewmodels/filesystem_vm import
  FilesystemVM, createFilesystemVM, setRoot, expandPath
import ../viewmodel/platform/web_entry
import ../viewmodel/platform/web_deployment
import ../viewmodel/platform/noir_template

when defined(js):
  from isonim/web/dom_api as isonim_dom import nil
  from ../viewmodel/views/isonim_filesystem_view import
    mountIsoNimFilesystemPanel

const templateSurfaceContainerId* = "main"
  ## `<section id="main">`, inside `#session-container-0` inside `#ROOT` — the
  ## container the entry document already ships and the one CodeTracer's own
  ## session components live in.
  ##
  ## Chosen rather than added, deliberately: the entry document is generated
  ## from `web_deployment.nim` and its skeleton is kept "structurally identical"
  ## to `src/frontend/index.html` on purpose, because §1a.1 says the web is a
  ## MODE of CodeTracer and "two divergent documents would be the first place
  ## that stops being true". A new id for the web would have been that
  ## divergence.
  ##
  ## ## Why not `#isonim-app`, which is the other free container
  ##
  ## Because it is INVISIBLE, and finding that out cost a full measurement
  ## cycle worth recording. `#isonim-app` sits before `#root-container` in the
  ## document, so `#session-container-0` paints over it completely. Mounted
  ## there, the panel measured perfect and showed the user nothing:
  ##
  ##     .filesystem-container  1440x168 at (0,44), display:flex, visible
  ##     a.jstree-anchor        color rgb(243,243,243) on rgb(27,27,27)
  ##     entryLabels            hello_noir src main.nr utils.nr tests …
  ##     innerText              422 characters, unchanged
  ##     elementFromPoint(row)  DIV.session-container    <- the whole story
  ##     screenshot             uniformly dark
  ##
  ## Every DOM assertion available was green over a blank page, `innerText`
  ## included — the text WAS rendered, it was covered, and `innerText` does not
  ## model occlusion. `ci/test/web-renderer-mounts.sh` arm R now hit-tests each
  ## row and arm V paints over the page to prove that check can fail, which is
  ## the assertion this paragraph exists to have earned.

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

var entrySurfaceVMStore: ReplayDataStore
var templateFilesystemVM*: FilesystemVM
var mountedTemplate*: ProjectTemplate

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
# The template, as a filesystem tree
# ---------------------------------------------------------------------------

proc templateEntryNode(tmpl: ProjectTemplate): FilesystemEntryNode =
  ## Build the Filesystem panel's tree out of the template's own file list.
  ##
  ## DERIVED, not written out a second time. A hand-built tree beside
  ## `noir_template.files` is two statements of the same project that a test
  ## could not tell apart until they disagreed — the shape
  ## `web_deployment.nim`'s header refuses for the asset list and
  ## `web_entry.nim`'s refuses for the prefix list. `templateDirectories`
  ## likewise derives the folders from the paths, so the panel cannot show a
  ## folder the project has no file in.
  var root = FilesystemEntryNode(
    id: "j1_0", text: tmpl.name, path: "", icon: "",
    isFolder: true, isExpanded: true, diffClass: fdcNone, children: @[])

  var nextId = 1
  # Folders first, in the order the file list implies, then the loose files.
  # That is the order §1a's picture shows (`src`, `tests`, `Nargo.toml`) and it
  # falls out of the data rather than being imposed on it.
  for directory in templateDirectories(tmpl):
    var folder = FilesystemEntryNode(
      id: "j1_" & $nextId, text: directory, path: directory, icon: "",
      isFolder: true, isExpanded: true, diffClass: fdcNone, children: @[])
    nextId += 1
    for file in tmpl.files:
      let prefix = directory & "/"
      if file.path.len > prefix.len and file.path[0 ..< prefix.len] == prefix and
         file.path.find('/', prefix.len) < 0:
        folder.children.add FilesystemEntryNode(
          id: "j1_" & $nextId, text: file.path[prefix.len .. ^1],
          path: file.path, icon: "", isFolder: false, isExpanded: false,
          diffClass: fdcNone, children: @[])
        nextId += 1
    root.children.add folder

  for file in tmpl.files:
    if file.path.find('/') >= 0: continue
    root.children.add FilesystemEntryNode(
      id: "j1_" & $nextId, text: file.path, path: file.path, icon: "",
      isFolder: false, isExpanded: false, diffClass: fdcNone, children: @[])
    nextId += 1

  root

proc templateTreeFor*(tmpl: ProjectTemplate): FilesystemEntryNode =
  ## Exported so `test_web_entry_surface` can assert the tree without a
  ## browser. The mount below is the same value put on a DOM, so a tree test
  ## and a rendered-DOM assertion are statements about one thing.
  templateEntryNode(tmpl)

when defined(js):
  proc ensureEntrySurfaceVm() =
    if not templateFilesystemVM.isNil:
      return
    # The same stub backend `ensureWelcomeScreenVm` builds, and for the reason
    # its comment gives: these panels have never needed a host, only the legacy
    # component wrappers did. A statically hosted tab has no host process and
    # never will.
    let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    let stubBackend = BackendService(
      sendProc: stubSend,
      onEventProc: proc(handler: proc(event: JsonNode)) = discard,
      disconnectProc: proc() = discard,
    )
    entrySurfaceVMStore = createReplayDataStore(stubBackend)
    templateFilesystemVM = createFilesystemVM(entrySurfaceVMStore)

  proc mountTemplateSurface*(tmpl: ProjectTemplate): bool =
    ## Mount the template project. Returns whether it mounted, so the caller
    ## reports a refusal rather than assuming — the convention
    ## `mountWebWelcomeScreen` set, and the one mutation arm B of the mount
    ## gate depends on.
    if not tmpl.hasFiles:
      return false
    ensureEntrySurfaceVm()
    if templateFilesystemVM.isNil:
      return false

    let container = isonim_dom.getElementById(isonim_dom.document,
                                              cstring(templateSurfaceContainerId))
    if container.isNil:
      return false

    let tree = templateEntryNode(tmpl)
    # `setRoot` also moves `loadingState` to `lsIdle`; without it the panel
    # renders its loading overlay over a tree that is already there, which
    # would be a surface that says the project is still arriving forever.
    templateFilesystemVM.setRoot(tree)
    templateFilesystemVM.expandPath("")
    for directory in templateDirectories(tmpl):
      templateFilesystemVM.expandPath(directory)

    isonim_dom.setAttribute(container, cstring"style", cstring"display: block")
    container.innerHTML = cstring""
    mountIsoNimFilesystemPanel(container, templateFilesystemVM)
    mountedTemplate = tmpl
    true
else:
  proc mountTemplateSurface*(tmpl: ProjectTemplate): bool = false
