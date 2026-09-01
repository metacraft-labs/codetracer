## The hosting contract — Noir-Studio.md §1b.4, as a value.
##
## "Small, and worth stating explicitly because it is the whole hosting
## contract": one 200-rewrite per prefix, three cache classes keyed on path
## prefix, no ID allocation endpoint, two narrow write surfaces.
##
## ## Why the contract is code rather than a `netlify.toml`
##
## Because it has to agree with `web_entry.nim`, and a hand-written host
## configuration cannot be made to. The failure it prevents is specific and
## cheap to reach: someone adds a form to `EntryForm`, the application handles
## it, and the CDN 404s it because nobody edited the rewrite list. So
## `rewritePrefixes` is derived from the same classification `resolveEntry`
## uses, and `test_every_entry_form_reaches_the_application` asserts the
## agreement rather than asserting a file's contents.
##
## The generated configuration is then emitted from here, so the deployment's
## file is an *output* and cannot drift from the product.
##
## ## The origin is a parameter with no default
##
## `ide.codetracer.com` is the product's host, and as of the 2026-08-29 rename
## `src/ct/online_sharing/remote_config.nim` agrees — the disagreement this
## paragraph used to record is resolved. No default appears here anyway, and
## the resolution is the reason rather than a reason against: the host has now
## moved twice (`cloud` → `web` → `ide`) and each move found a constant
## somebody had to hunt for. A default is a constant with a friendly face, so
## every proc that needs a host takes it.

import std/[json, strutils]

import ./web_entry

type
  CacheClass* = enum
    ## §1b.4's three rows. Named rather than expressed as header strings at
    ## call sites, because the whole point of the table is that the class
    ## follows from the path prefix and nothing else.
    ccEntryDocument
      ## Mutable. Short TTL, revalidated.
    ccImmutable
      ## `/s/*`. Content-addressed, so cacheable forever.
    ccPointer
      ## `/p/*/current.json`. Short TTL plus stale-while-revalidate.
    ccStaticAsset
      ## The bundle's own hashed assets. Not in §1b.4's table because they are
      ## not an *address* of the product, but they exist and would otherwise be
      ## served under the entry document's class, which would be wrong in the
      ## expensive direction.

  RewriteRule* = object
    ## A 200-rewrite, never a redirect. §1b.4: "served **200 rather than 302**".
    prefix*: string
    servesEntryDocument*: bool

  CacheRule* = object
    pattern*: string
      ## The host's own path pattern, emitted verbatim. A *pattern* rather than
      ## a prefix because §1b.4's mutable-pointer row is `/p/*/current.json`,
      ## which a bare prefix cannot express — and expressing it as `/p/` was the
      ## defect review found here: it put the pointer's
      ## `stale-while-revalidate` on the SPA entry document served at every
      ## project address.
    class*: CacheClass
    headerValue*: string

  WriteSurface* = object
    ## §1b.4: "**Two write surfaces**, both narrow: publishing a snapshot
    ## (§6.1), and moving a project's pointer."
    name*: string
    path*: string
    needsAccount*: bool
    outageDegrades*: string
      ## "An outage of either degrades *creating and updating* while every
      ## existing link keeps working, because the read path is files."

  DeploymentContract* = object
    origin*: string
    rewrites*: seq[RewriteRule]
    caches*: seq[CacheRule]
    writeSurfaces*: seq[WriteSurface]
    identifierAllocationEndpoints*: seq[string]
      ## §1b.4: "**No ID allocation endpoint**, by rule 3". Empty, and empty as
      ## a value a test reads rather than as a sentence nobody checks.

const
  entryDocumentHeader* = "public, max-age=60, must-revalidate"
  immutableHeader* = "public, max-age=31536000, immutable"
  pointerHeader* = "public, max-age=30, stale-while-revalidate=86400"
  staticAssetHeader* = "public, max-age=31536000, immutable"

  snapshotPrefix* = "/s/"
  projectPrefix* = "/p/"
  staticAssetPrefix* = "/assets/"

proc rewritePrefixes*(): seq[string] =
  ## Derived from `web_entry`'s classification, not written out again.
  ##
  ## §1b.4: "The rewrite is per-prefix rather than one glob, because the
  ## language entry points and the language-neutral namespaces are separate
  ## roots (rule 0)." A single `/*` glob would also swallow the static assets
  ## and the two write surfaces, so the per-prefix form is load-bearing rather
  ## than tidy.
  for language in knownLanguageEntries:
    result.add "/" & language
  # `/new` is the clean-start address on a host whose ROOT is already the
  # language — `noirstudio.dev/new`. It is one rewrite table for one tree
  # serving every host the project has, so the prefix is emitted
  # unconditionally; on a language-neutral host `/new` classifies `efUnknown`
  # and §1b.3 step 6 opens the template with a sentence saying so, which is
  # that step's prescribed answer and not an error page.
  result.add "/new"
  result.add "/s"
  result.add "/p"
  result.add "/projects"
  result.add "/collab/join"

const pointerObjectSuffix* = "/current.json"

proc cacheClassFor*(path: string): CacheClass =
  ## The class a CDN must apply, from the path alone.
  ##
  ## ## Two of the four classes used to be unreachable from here, which is the
  ## ## shape this campaign keeps finding
  ##
  ## The first version answered `ccEntryDocument` for everything under `/p/`
  ## and never returned `ccPointer` or `ccStaticAsset` at all. The suite still
  ## passed, because it asserted `headerFor(ccPointer)` directly — a header
  ## table can be right while nothing ever selects the row. The generated
  ## configuration made the mirror-image mistake and put the pointer's
  ## `stale-while-revalidate` on the WHOLE `/p/` prefix, so the SPA entry
  ## document at a project address would have been served up to a day stale.
  ## §1b.4's table names `/p/*/current.json`, not `/p/*`, and the two halves
  ## now agree because `deploymentContract` reads its prefixes from the same
  ## constants this function does.
  if path.len >= pointerObjectSuffix.len and
     path[path.len - pointerObjectSuffix.len .. ^1] == pointerObjectSuffix and
     classifyPath(path).form == efProject:
    return ccPointer
  if path.len >= staticAssetPrefix.len and
     path[0 ..< staticAssetPrefix.len] == staticAssetPrefix:
    return ccStaticAsset
  let classified = classifyPath(path)
  case classified.form
  of efSnapshot: ccImmutable
  of efProject:
    # `/p/<locator>` itself is the SPA entry document; only the pointer object
    # under it is mutable-and-cacheable, and it was handled above.
    ccEntryDocument
  else: ccEntryDocument

proc pointerPath*(slug, projectId: string): string =
  ## §1b.1's `current.json`.
  projectPath(slug, projectId) & pointerObjectSuffix

# ---------------------------------------------------------------------------
# What the bundle must actually CARRY
#
# NS3's residual, in one sentence from `host/web_browser.nim`: the registry,
# the protocol, the transport and `newBrowserWasmHost` all exist and are
# tested, and none of it is reachable, because "the worker script that
# instantiates the Noir modules and drives their `nv_*` / `ct_*` ABIs is not in
# the bundle". NS3 moved from *nothing loads a module* to *nothing delivers
# one*. This is the delivery manifest.
#
# WHY IT IS A VALUE HERE RATHER THAN A LIST IN A SHELL SCRIPT. The same
# argument the header makes for `rewritePrefixes`: a hand-written list in the
# assembly step cannot be made to agree with the product. `web_deployment.nim`
# is compiled by `vm-unit` (C) and `vm-unit-js` (JS), so an asset added here is
# type-checked on both backends and read by ONE assembly step and ONE gate,
# rather than being spelled three times and drifting twice.
#
# THE THREE DELIVERY MODES ARE DIFFERENT DECISIONS AND ARE MODELLED AS SUCH.
# "Bundle it, emit it, or fetch it" is not a matter of taste per asset:
#
#   damBundled   it is Nim compiled to JS and linked into an entry point. The
#                renderer is this, and could not be anything else.
#   damAsset     a file the deployment serves, loaded by URL at run time. The
#                worker script is this BECAUSE `new Worker(url)` takes a URL
#                and `newBrowserWasmHost(registry, scriptUrl)` already has the
#                parameter. Inlining it and building a `blob:` URL would be
#                rejected by any `Content-Security-Policy` worth setting and
#                would be uncacheable besides.
#   damFetched   a file fetched on first use and never at load. The two Noir
#                wasm modules are this because they are ~16 MB and ~4.6 MB: a
#                bundled copy inflates by a third as base64 AND must be parsed
#                as JavaScript source before the first paint, for a capability
#                most sessions never invoke. Fetched, they are `ccImmutable`
#                and cached indefinitely.
# ---------------------------------------------------------------------------

type
  DeliveryMode* = enum
    damBundled
    damAsset
    damFetched
    damEntryDocument
      ## The document itself. Its own row, and not `damAsset`, because the two
      ## differ in the one property the cache table is about: a `damAsset` is
      ## content-addressed under `/assets/` and served `immutable`, and the
      ## entry document is the mutable thing every rewrite in this file points
      ## at. Filing it as an asset would have put a year's `immutable` on the
      ## application shell, which is the failure `cacheClassFor`'s own header
      ## already records once in the other direction.
      ##
      ## It is on the manifest at all because it was the asset nothing
      ## produced. `renderRewriteConfig` emits `/index.html` as the target of
      ## every prefix, `webRuntimeAssets()` did not name it, and so no
      ## assembly step made one — the bundle carried a renderer, an entry
      ## point and a worker, and no page to load any of them from. That is
      ## this repository's signature defect (a thing that builds and is never
      ## delivered) in the one place it could not be seen, because the gate
      ## checked the manifest and the manifest did not mention the document.

  RuntimeAsset* = object
    ## One file a web deployment must carry for the product to work.
    id*: string
      ## Stable name. For a wasm module this is the registry id the worker
      ## receives in its `configure` message, so the two cannot drift.
    path*: string
      ## Where the assembly step places it, relative to the bundle root.
    mode*: DeliveryMode
    required*: bool
      ## False for an asset whose absence degrades rather than breaks. The two
      ## wasm modules are optional in exactly the sense
      ## `wasm_registry.noWasmModules()` already models: a deployment that
      ## ships none is a TRUE statement about that deployment, and the user
      ## reads `webNoModulesLoaded` rather than meeting a run that fails.
    absenceBehaviour*: string
      ## What a user gets when an optional asset is not shipped. Same rule as
      ## `capabilities.degradedBehaviour`: an absence without a stated
      ## consequence is a gap in the product, not a gap in the docs.

const
  entryDocumentPath* = "index.html"
    ## Where the assembly step WRITES the entry document.

  entryDocumentAddress* = "/"
    ## Where a rewrite must POINT at it, which is not the same string, and the
    ## difference is a defect that reached production and stayed there.
    ##
    ## ## Measured on `ide.codetracer.com`, 2026-09-01
    ##
    ## `renderRewriteConfig` emitted `/index.html` as every rule's target. On
    ## Cloudflare Pages the result was:
    ##
    ##     /noir            308 -> /          the rule fired
    ##     /projects        308 -> /          the rule fired
    ##     /s               308 -> /          the rule fired
    ##     /p               308 -> /          the rule fired
    ##     /collab/join     308 -> /          the rule fired
    ##     /index.html      308 -> /          and here is why
    ##     /noir/new        200                no exact rule; served anyway
    ##     /nope            200                no rule at all; served anyway
    ##
    ## Pages normalises `/index.html` to `/` with a 308 — the same automatic
    ## clean-URL rewrite that turns `/replay-demo.html` into `/replay-demo`,
    ## which this deployment also serves and which is how the mechanism was
    ## identified. Applying it to a rewrite TARGET converts the 200-rewrite
    ## into a redirect, so the one line of §1b.4 that is stated in capitals —
    ## "served **200 rather than 302**" — was violated by every rule that
    ## actually matched.
    ##
    ## The user-visible defect is the whole of the bug report: typing
    ## `ide.codetracer.com/noir` moved the address bar to `/`, so the language
    ## was destroyed by the CDN *before any script ran*. No amount of correct
    ## client-side routing could have survived it — `currentEntryRequest()`
    ## would have read `/`, classified it as a language-neutral root, and been
    ## right about the URL it was given.
    ##
    ## ## Why the fix is a different target and not a different status
    ##
    ## `renderRewriteConfig`'s own comment says why the status cannot move:
    ## "a `301` or `302` here would break the SPA's own history handling and
    ## would make `/noir/new`'s history replacement (rule 5) impossible."
    ## That remains true. What changes is the target: `/` is already the
    ## canonical address of the entry document on every static host in use, so
    ## there is no normalisation left to apply to it.
    ##
    ## ## THE COST WAS NOT TRANSIENT, AND THIS IS THE PART WORTH REMEMBERING
    ##
    ## A wrong redirect on an SPA entry path is not a bug that ends when the
    ## deploy is fixed. `308` is a PERMANENT redirect and Cloudflare sent it
    ## with **no `Cache-Control` at all**, so browsers cache it heuristically
    ## and treat it as permanent. Measured with a persistent Chromium profile
    ## against a fixture reproducing both deployments:
    ##
    ##     phase 1, old deploy (308)      /noir -> / , welcome screen
    ##     phase 2, FIXED deploy, SAME
    ##       browser                      /noir -> / , welcome screen
    ##     phase 3, fixed deploy, fresh
    ##       browser                      /noir      , the template
    ##
    ## Phase 2 is the finding: the browser never asks the server again. Every
    ## visitor who opened `ide.codetracer.com/noir` during the ~13 hours the
    ## defect was live is still redirected, and no deployment can revoke it —
    ## the request is not made. A normal reload does not clear it; only a
    ## different URL (`/noir/`, which is a different cache key and which the
    ## classifier resolves identically) or clearing the cache does.
    ##
    ## That is why `web-renderer-mounts.sh` arm D and the deploy's
    ## `--max-redirs 0` status check are not cosmetic. A 3xx on an entry path
    ## is a defect that outlives its own fix, in the caches of exactly the
    ## people who tried the product first.
    ##
    ## ## Why the rules are kept rather than deleted
    ##
    ## Deleting them would also have "fixed" `/noir`, because Pages serves its
    ## SPA fallback for anything it cannot resolve — that is why `/nope`
    ## answers 200 above. Relying on it would make §1b.4's hosting contract an
    ## undocumented behaviour of one vendor, and would silently stop covering
    ## a prefix the day a `404.html` is added to the bundle. The contract stays
    ## explicit and stays generated from `rewritePrefixes()`.
  rendererBundlePath* = "ui.js"
    ## THE ONLY NIM BUNDLE A DEPLOYMENT CARRIES, as of NS9.
    ##
    ## There used to be a second, `web.js`, built from `web_main.nim` and
    ## loaded before this one: the "loop arm" installed the platform and the
    ## renderer painted. They could not be one program's worth of state and
    ## never were. `installPlatform` writes a module-level `var` in
    ## `platform/platform.nim`, `nim js` gives each compiled program its own,
    ## and `ci/test/web-bundle-assets.sh` wraps each bundle in an IIFE — which
    ## is load-bearing, because otherwise the second redefines 196 of the
    ## first's functions and 85 of its type tables — so the scoping that kept
    ## them from corrupting each other is exactly what kept them from sharing
    ## anything. The renderer's `ctPlatform()` therefore returned the refusing
    ## `uninstalledProfile` on every load of the deployed page, and the 19 MB
    ## of Noir compiler this manifest places was unreachable from the only code
    ## that could have called it.
    ##
    ## Merging cost nothing and saved 380,418 bytes: the shared runtime is
    ## emitted once. `web_main.nim` still exists as `web-bundle-smoke.sh`'s
    ## headless boot entry point; it is not deployed.

  # THE THREE ASSETS THE RENDERER HAS ALWAYS NEEDED AND THIS MANIFEST NEVER
  # NAMED, which is why a correct-looking deployment painted nothing.
  #
  # `ui.js` is not a self-contained program and never has been. On the desktop
  # it is the LAST of three scripts in `src/frontend/index.html`: the webpack
  # bundle publishes `monaco`, `GoldenLayout`, `Mousetrap`, `jQuery` and eight
  # more onto `window` first, and only then does the renderer load. Delivered
  # without it, `ui.js` throws
  #
  #     Uncaught ReferenceError: monaco is not defined
  #
  # during module initialisation — `ui/agent_activity.nim:46` builds two Monaco
  # models at module scope — and dies about a quarter of the way through its
  # own top-level code. Nothing downstream of that line ever ran, which is the
  # whole of "the renderer was delivered and never started".
  #
  # It was invisible to every check because each of them was true: the bundle
  # built, the document referenced it, the file was served at the size it was
  # uploaded at, and the boot arm reported `ok`. None of them is *a page that
  # paints*, and the manifest is where that difference has to be written down —
  # `web-bundle-assets.sh` places what this names, so an asset absent from here
  # is an asset no deployment carries.
  #
  # PATHS MIRROR THE DESKTOP TREE, deliberately. The compiled theme references
  # `../../libs/codetracer-design-system/...` and the renderer requests
  # `public/resources/shared/codetracer_welcome_logo.svg`; both are resolved
  # relative to these locations. Relocating the CSS under `/assets/` for its
  # cache class would silently 404 every font and the product logo, so the
  # layout is kept and the cache class is the one `cacheClassFor` gives a
  # non-`/assets/` path.
  rendererThemeStylesPath* = "frontend/styles/default_dark_theme_electron.css"
  rendererLoaderStylesPath* = "frontend/styles/loader.css"
  thirdPartyBundlePath* = "public/dist/frontend_bundle.js"
  wasmWorkerScriptPath* = staticAssetPrefix[1 .. ^1] & "wasm-worker.js"
  noirCompilerModuleId* = "noir-compiler"
  noirTracerModuleId* = "noir-tracer"
  noirCompilerWasmPath* = staticAssetPrefix[1 .. ^1] & "noir_wasm.wasm"
  noirTracerWasmPath* = staticAssetPrefix[1 .. ^1] & "noir_tracer_wasm.wasm"

proc webRuntimeAssets*(): seq[RuntimeAsset] =
  ## Everything a web deployment serves, in delivery order.
  @[
    RuntimeAsset(
      id: "entry-document", path: entryDocumentPath, mode: damEntryDocument,
      required: true, absenceBehaviour: ""),
    RuntimeAsset(
      id: "renderer", path: rendererBundlePath, mode: damBundled,
      required: true, absenceBehaviour: ""),
    RuntimeAsset(
      id: "third-party-bundle", path: thirdPartyBundlePath, mode: damBundled,
      required: true, absenceBehaviour: ""),
    RuntimeAsset(
      id: "renderer-theme", path: rendererThemeStylesPath, mode: damBundled,
      required: true, absenceBehaviour: ""),
    RuntimeAsset(
      id: "renderer-loader-styles", path: rendererLoaderStylesPath,
      mode: damBundled, required: true, absenceBehaviour: ""),
    RuntimeAsset(
      id: "wasm-worker", path: wasmWorkerScriptPath, mode: damAsset,
      required: true,
      absenceBehaviour: ""),
    RuntimeAsset(
      id: noirCompilerModuleId, path: noirCompilerWasmPath, mode: damFetched,
      required: false,
      absenceBehaviour:
        "Noir compilation is unavailable and `nargo compile` is reported as " &
        "having no wasm build in this deployment, by name, rather than " &
        "failing part-way through a run"),
    RuntimeAsset(
      id: noirTracerModuleId, path: noirTracerWasmPath, mode: damFetched,
      required: false,
      absenceBehaviour:
        "a compiled Noir program cannot be traced in the tab, so replay is " &
        "offered only for recordings produced elsewhere")]

proc requiredRuntimeAssets*(): seq[RuntimeAsset] =
  for asset in webRuntimeAssets():
    if asset.required: result.add asset

proc fetchedRuntimeAssets*(): seq[RuntimeAsset] =
  ## The assets the worker resolves by URL. `wasm_worker_browser.js` receives
  ## exactly these ids in its `configure` message.
  for asset in webRuntimeAssets():
    if asset.mode == damFetched: result.add asset

proc undeclaredAbsences*(): seq[string] =
  ## Every optional asset that does not say what its absence costs. The
  ## assertion is `.len == 0` over this, mirroring
  ## `capabilities.undeclaredDegradations` — a manifest that lets an optional
  ## asset in without a consequence is a table that has stopped describing the
  ## product.
  for asset in webRuntimeAssets():
    if not asset.required and asset.absenceBehaviour.len == 0:
      result.add asset.id

proc headerFor*(class: CacheClass): string =
  case class
  of ccEntryDocument: entryDocumentHeader
  of ccImmutable: immutableHeader
  of ccPointer: pointerHeader
  of ccStaticAsset: staticAssetHeader

proc deploymentContract*(origin: string): DeploymentContract =
  ## The whole contract, for a named origin. No default — see the header.
  result.origin = origin
  for prefix in rewritePrefixes():
    result.rewrites.add RewriteRule(prefix: prefix, servesEntryDocument: true)
  # Most specific first, because `renderCacheConfig` emits them in order and
  # every host in use takes the first matching rule. The pointer rule is
  # `/p/*/current.json` and NOT `/p/*`: the project address itself is the SPA
  # entry document, and giving it the pointer's `stale-while-revalidate` would
  # serve a returning user a day-old application bundle.
  result.caches = @[
    CacheRule(pattern: projectPrefix & "*" & pointerObjectSuffix,
              class: ccPointer, headerValue: pointerHeader),
    CacheRule(pattern: snapshotPrefix & "*", class: ccImmutable,
              headerValue: immutableHeader),
    CacheRule(pattern: staticAssetPrefix & "*", class: ccStaticAsset,
              headerValue: staticAssetHeader),
    CacheRule(pattern: "/*", class: ccEntryDocument,
              headerValue: entryDocumentHeader)]
  result.writeSurfaces = @[
    WriteSurface(
      name: "publish a snapshot",
      path: "/api/snapshot",
      needsAccount: true,
      outageDegrades:
        "new snapshots cannot be created; every snapshot already published " &
        "keeps working, because reading one is a static file"),
    WriteSurface(
      name: "move a project pointer",
      path: "/api/project/pointer",
      needsAccount: true,
      outageDegrades:
        "a project's saved state stops advancing; every project URL keeps " &
        "resolving to the last snapshot its pointer named")]
  result.identifierAllocationEndpoints = @[]

proc absoluteUrl*(origin, path, fragment: string): string =
  ## The only place a full URL is assembled.
  ##
  ## Note there is no `query` parameter, and that is the enforcement of
  ## §1b.0 rule 2 rather than a convenience: a builder that cannot express a
  ## query string cannot leak a file path into a CDN access log, whatever a
  ## future call site intends. `web_entry.declaredQueryParameters` is the
  ## matching assertion on the reading side.
  result = origin & path
  if fragment.len > 0:
    result.add "#"
    result.add fragment

proc renderRewriteConfig*(contract: DeploymentContract): string =
  ## The deployment's rewrite file, in the `_redirects` form every static host
  ## in use understands. `200` in the status column is the 200-rewrite §1b.4
  ## requires; a `301` or `302` here would break the SPA's own history handling
  ## and would make `/noir/new`'s history replacement (rule 5) impossible.
  result = "# Generated from viewmodel/platform/web_deployment.nim. Do not edit.\n"
  result.add "# Noir-Studio.md §1b.4 — one 200-rewrite per prefix.\n"
  result.add "# The target is `" & entryDocumentAddress &
    "` and not `/" & entryDocumentPath & "`; see that constant for the 308.\n"
  for rule in contract.rewrites:
    result.add rule.prefix & "/*  " & entryDocumentAddress & "  200\n"
    result.add rule.prefix & "  " & entryDocumentAddress & "  200\n"

proc rewriteTargets*(contract: DeploymentContract): seq[string] =
  ## Every target `renderRewriteConfig` emits, as a value.
  ##
  ## Written so `test_no_rewrite_targets_a_normalised_path` can assert over the
  ## targets rather than grep the rendered text: the rendering is one string
  ## and a grep for `/index.html` in it would also match the comment line
  ## above, which is the kind of check that passes for the wrong reason.
  for rule in contract.rewrites:
    result.add entryDocumentAddress
    result.add entryDocumentAddress

proc normalisedRewriteTargets*(contract: DeploymentContract): seq[string] =
  ## The targets a static host would answer with a redirect instead of the
  ## document — §1b.4's "200 rather than 302", checked rather than promised.
  ##
  ## One entry per offending target, so the assertion is `.len == 0` and a
  ## failure names the string. `/index.html` is the only member today and it is
  ## the one that shipped; the test that reads this is the reason a future
  ## edit back to it fails a suite rather than a deployment.
  for target in rewriteTargets(contract):
    if target.len >= entryDocumentPath.len and
       target[target.len - entryDocumentPath.len .. ^1] == entryDocumentPath:
      result.add target

proc renderCacheConfig*(contract: DeploymentContract): string =
  result = "# Generated from viewmodel/platform/web_deployment.nim. Do not edit.\n"
  result.add "# Noir-Studio.md §1b.4 — three cache classes keyed on path prefix.\n"
  result.add "# Most specific first: the first matching rule wins.\n"
  for rule in contract.caches:
    result.add rule.pattern & "\n"
    result.add "  Cache-Control: " & rule.headerValue & "\n"

# ---------------------------------------------------------------------------
# WHAT A DEPLOYMENT SAYS IT DELIVERED
#
# `webRuntimeAssets()` above is a statement of INTENT — what a bundle must
# carry. This section is the statement of FACT — what one particular deployment
# actually placed, written by the assembly step from the bytes on disk and read
# back by the running page.
#
# The two are deliberately different values, and conflating them is the defect
# this whole section exists to prevent. `host/web_browser.nim` records the rule
# it must not break: "declaring `nargo` over modules that were never placed
# would put `capProcessSpawn` back on a profile whose every run fails". A page
# that derived its capabilities from the INTENT manifest would do exactly that
# — the manifest names both Noir modules on every build, including the builds
# that ship neither.
#
# ## Why the descriptor travels IN the entry document and is not fetched
#
# This is the constraint that decided the design, and it is not a preference.
# `ci/test/noir-studio-signed-out.sh` asserts that the boot sequence —
# `web_main.nim`, which carries write, compile, run, record and export —
# contains **zero network egress sites**, and that is what makes the loop
# work signed out and on a plane. A `fetch('/assets/deployment.json')` in
# `boot()` would be the first one, and it would be an egress site on the
# critical path of a product whose whole claim is that it has none.
#
# So the deployment describes itself in the document it is already serving. The
# page reads a `<script type="application/json">` out of its own DOM — not a
# request, not a redirect, and readable before the first paint. It is the same
# shape BlockTracer's pages use for `data-replay-engine`, and it has the
# property that matters here: the declaration and the bytes are published in
# the same upload, so a deploy guard can check them against each other.
#
# ## The four states a module can be in, which must not collapse into one
#
#   not declared, not served   the deployment ships no toolchain. The registry
#                              is empty and `resolve` answers
#                              `wrNoModulesLoaded` — case (0), a fact about the
#                              deployment.
#   declared and served        it runs.
#   declared, NOT served       a BROKEN DEPLOY. The document promises a module
#                              the publish directory does not contain, so the
#                              worker's fetch 404s. This is the state
#                              `deployGuardDefects` below refuses to publish,
#                              and the reason it is a distinct state rather
#                              than "the module failed" is that a missing file
#                              and a broken module need different people.
#   served, not declared       dead weight: 16 MB nothing can reach. Also a
#                              guard failure, in the other direction.
# ---------------------------------------------------------------------------

type
  OriginLanguage* = object
    ## One origin this deployment serves, and the language its ROOT means.
    ##
    ## Matched WHOLE and exactly — `https://noirstudio.dev` is not
    ## `https://www.noirstudio.dev`, and a deployment that serves both declares
    ## both. There is deliberately no normalisation, no suffix rule and no
    ## wildcard here: every one of those is a place where the product would
    ## start deciding which hosts exist, and which hosts exist is the
    ## deployment's fact. A host the deployment forgot to declare falls back to
    ## the language-neutral root, which is a working product at a generic
    ## entry point rather than a broken one.
    origin*: string
    language*: string
      ## A `web_entry.knownLanguageEntries` value. Checked at the boundary by
      ## `parseDeploymentDescriptor`, so an origin declaring a language the
      ## product does not have is dropped rather than routed to a template that
      ## does not exist.

  DeployedModule* = object
    ## One wasm module a particular deployment placed AND declared.
    id*: string
      ## A `webRuntimeAssets()` asset id, so this cannot drift from the
      ## manifest without `deployGuardDefects` saying so.
    url*: string
      ## Root-relative, and the exact string the worker receives in its
      ## `configure` message.
    bytes*: int
      ## What the assembly step measured. Carried so the page can report a
      ## size before it fetches, and so the guard can compare the document's
      ## claim against the file it is about to upload — the "verify the
      ## deployed artifact, not the green workflow" rule, applied to the bytes
      ## rather than to a log line.
    builtFrom*: string
      ## Provenance, in `noir_wasm_modules.deliveredProvenance`'s form —
      ## `noir@codetracer <rev> compiler/wasm`. A module that cannot say where
      ## it came from is DROPPED by `registrableModules`, so this is not
      ## decoration: an empty string here silently disables the module.

  DeploymentDescriptor* = object
    origin*: string
    revision*: string
      ## The codetracer commit the bundle was built from.
    modules*: seq[DeployedModule]
    languageOrigins*: seq[OriginLanguage]
      ## WHICH HOSTS ARE LANGUAGE ENTRY POINTS, declared by the deployment.
      ##
      ## `noirstudio.dev` is meant to be the Noir entry point the way
      ## `ide.codetracer.com/noir` is — same tree, same bundle, no redirect,
      ## and the visitor stays on the domain they typed. Cloudflare Pages
      ## serves any number of custom domains from one project, so nothing about
      ## the ARTIFACT needs to differ; what differs is what `/` means, and that
      ## is one string the page can read about itself.
      ##
      ## It travels in the descriptor rather than being compiled in, for the
      ## reason `web_entry.nim`'s header gives about origins generally: the
      ## product's host has already moved twice and each move found a constant.
      ## A deployment that adds a second domain is a deploy-time argument here,
      ## not a code change and not a rebuild.
      ##
      ## And it travels in the DOCUMENT rather than being fetched, for the
      ## reason this section's header gives: the development loop is asserted
      ## to have ZERO egress sites (`ci/test/noir-studio-signed-out.sh`), and a
      ## request for the host map would be the first. Reading
      ## `window.location.origin` and matching it against a value already in
      ## the page costs nothing.

const
  deploymentDescriptorElementId* = "codetracer-deployment"
    ## The `<script type="application/json">` the page reads itself out of.
    ## Exported because three things must agree on it: this renderer,
    ## `host/web_browser.nim`'s DOM read, and the deploy guard's grep.

proc jsonStringForHtml(node: JsonNode): string =
  ## `$node`, made safe to place inside a `<script>` element.
  ##
  ## An HTML parser looks for the literal `</script` inside a script element's
  ## text and ends the element there, whatever the JSON means. A provenance
  ## string or a URL containing it would truncate the document — so `<` is
  ## escaped to `<`, which is the same string to a JSON reader and inert
  ## to an HTML one. `&` and `>` go with it for the usual belt-and-braces
  ## reason.
  ##
  ## This is not a hypothetical tidy-up: the descriptor carries strings that
  ## come from a build environment (a branch name reaches `revision`), and an
  ## entry document that can be truncated by its own metadata is a page that
  ## fails with a syntax error naming nothing.
  result = $node
  result = result.replace("<", "\\u003c")
  result = result.replace(">", "\\u003e")
  result = result.replace("&", "\\u0026")

proc renderDeploymentDescriptor*(descriptor: DeploymentDescriptor): string =
  ## The descriptor as the JSON text the entry document carries.
  var modules = newJArray()
  for module in descriptor.modules:
    modules.add %*{
      "id": module.id,
      "url": module.url,
      "bytes": module.bytes,
      "builtFrom": module.builtFrom}
  var languageOrigins = newJArray()
  for entry in descriptor.languageOrigins:
    languageOrigins.add %*{
      "origin": entry.origin,
      "language": entry.language}
  jsonStringForHtml(%*{
    "origin": descriptor.origin,
    "revision": descriptor.revision,
    "modules": modules,
    "languageOrigins": languageOrigins})

proc parseDeploymentDescriptor*(text: string): DeploymentDescriptor =
  ## The inverse, tolerant of everything except a lie.
  ##
  ## A DEPLOYMENT WITH NO DESCRIPTOR IS A LEGITIMATE DEPLOYMENT — an empty
  ## result means "this deployment declares no modules", which is the true
  ## answer for a bundle built without them and produces `noWasmModules()`
  ## downstream. So malformed input yields the empty descriptor rather than an
  ## exception: the failure mode of a page that throws during boot is a blank
  ## screen, and the failure mode of this returning empty is the product
  ## saying, by name, that it ships no toolchain. The second is better and it
  ## is also true.
  ##
  ## What it will NOT do is invent a module. A module entry missing its id, its
  ## url or its provenance is dropped, because each of those absences makes it
  ## unusable and a half-declared module is the state that produces a run that
  ## fails late instead of a capability that is honestly absent.
  if text.strip().len == 0: return DeploymentDescriptor()
  var parsed: JsonNode
  try:
    parsed = parseJson(text)
  except:
    # A bare `except` for the reason `wasm_worker.nim`'s `deliver` records at
    # length: on the JS backend `parseJson` defers to V8's `JSON.parse`, which
    # throws a raw `SyntaxError` that `except CatchableError` does not catch.
    # The narrow form crashed the tab there while working on C.
    return DeploymentDescriptor()
  if parsed.kind != JObject: return DeploymentDescriptor()
  result.origin = parsed{"origin"}.getStr
  result.revision = parsed{"revision"}.getStr
  let modules = parsed{"modules"}
  if modules.isNil or modules.kind != JArray: return
  for entry in modules:
    if entry.kind != JObject: continue
    let module = DeployedModule(
      id: entry{"id"}.getStr,
      url: entry{"url"}.getStr,
      bytes: entry{"bytes"}.getInt,
      builtFrom: entry{"builtFrom"}.getStr)
    if module.id.len == 0 or module.url.len == 0 or module.builtFrom.len == 0:
      continue
    result.modules.add module

  let languageOrigins = parsed{"languageOrigins"}
  if languageOrigins.isNil or languageOrigins.kind != JArray: return
  for entry in languageOrigins:
    if entry.kind != JObject: continue
    let declared = OriginLanguage(
      origin: entry{"origin"}.getStr,
      language: entry{"language"}.getStr)
    if declared.origin.len == 0 or declared.language.len == 0: continue
    # A LANGUAGE THE PRODUCT DOES NOT HAVE IS DROPPED HERE, at the boundary,
    # rather than carried to `templateFor` and discovered as an empty surface.
    # Same rule as a module missing its provenance three lines up: a
    # half-valid declaration is what produces a route that mounts nothing.
    var known = false
    for language in knownLanguageEntries:
      if language == declared.language: known = true
    if not known: continue
    result.languageOrigins.add declared

proc languageForOrigin*(descriptor: DeploymentDescriptor;
                        origin: string): string =
  ## The language an origin's ROOT means, or "" for the language-neutral host.
  ##
  ## Pure, total, and the only place an origin is compared to anything. The
  ## classifier takes this string as `hostLanguage` and never sees an origin,
  ## which is what keeps `classifyPath` decidable offline from two strings.
  if origin.len == 0: return ""
  for entry in descriptor.languageOrigins:
    if entry.origin == origin: return entry.language
  ""

proc unmatchableLanguageOrigins*(descriptor: DeploymentDescriptor): seq[string] =
  ## Declared language origins that `window.location.origin` can never equal,
  ## with the reason. Asserted empty by the assembly step.
  ##
  ## ## Why this is a separate check and not a rule in the parser
  ##
  ## Because the failure it catches is a TYPO AT DEPLOY TIME, and its symptom
  ## is indistinguishable from success: a `noirstudio.dev` declared with a
  ## trailing slash, or as `http://`, or as a bare hostname, simply never
  ## matches — so the domain serves a perfectly working product at the
  ## language-neutral root and nothing anywhere says the map was ignored. That
  ## is this campaign's recurring shape (a correct declaration nothing
  ## consults) with the declaration itself as the defect.
  ##
  ## It is checked where the value is WRITTEN rather than where it is read, and
  ## `parseDeploymentDescriptor` deliberately does NOT drop these: a test
  ## harness serves the bundle over plain HTTP on a loopback origin, and a
  ## parser that refused `http://` would make the two-domain routing untestable
  ## without TLS. The build asserts the shape; the parser stays tolerant.
  ##
  ## `window.location.origin` is always `<scheme>://<host>[:<port>]` with no
  ## path and no trailing slash, which is the whole basis of every rule here.
  for entry in descriptor.languageOrigins:
    if entry.origin.len > 0 and entry.origin[^1] == '/':
      result.add entry.origin &
        " (a trailing slash: window.location.origin never has one)"
      continue
    var hasScheme = false
    for i in 0 ..< entry.origin.len - 2:
      if entry.origin[i] == ':' and entry.origin[i + 1] == '/' and
         entry.origin[i + 2] == '/':
        hasScheme = true
        break
    if not hasScheme:
      result.add entry.origin &
        " (no scheme: an origin is <scheme>://<host>, not a bare hostname)"
      continue
    if entry.origin.len < 8 or entry.origin[0 ..< 8] != "https://":
      result.add entry.origin &
        " (not https: a public language entry point served over http is " &
        "either a typo or a downgrade, and the CDN redirects http to https " &
        "so the page would never report this origin anyway)"

proc declaredLanguageOrigins*(descriptor: DeploymentDescriptor): seq[string] =
  ## For the deploy log and the gate: which hosts this deployment says are
  ## language entry points, so a two-domain deployment can be SEEN to be one.
  for entry in descriptor.languageOrigins:
    result.add entry.origin & "=" & entry.language

proc declaredModuleUrls*(descriptor: DeploymentDescriptor):
    seq[tuple[id: string, url: string]] =
  ## What the worker's `configure` message needs, in declaration order.
  for module in descriptor.modules:
    result.add (id: module.id, url: module.url)

proc deployGuardDefects*(descriptor: DeploymentDescriptor;
                         servedPaths: seq[string]): seq[string] =
  ## Everything wrong between what a document DECLARES and what a publish
  ## directory CONTAINS, as sentences. Empty is the assertion the deploy makes
  ## on the bytes it is about to upload.
  ##
  ## This is the check that would have caught the BlockTracer replay engine
  ## going to production at 18 MB with no page referencing it, and the mirror
  ## failure — a page referencing an engine nobody published — that cost a day
  ## after it. Both directions, because they are different mistakes made by
  ## different edits, and a guard that only ran one way would have been green
  ## on one of the two.
  ##
  ## `servedPaths` are root-relative with a leading slash, as the URLs are.
  let declarable = fetchedRuntimeAssets()
  for module in descriptor.modules:
    var known = false
    for asset in declarable:
      if asset.id == module.id: known = true
    if not known:
      result.add "the entry document declares wasm module `" & module.id &
        "`, which the runtime asset manifest does not name"
    if module.url notin servedPaths:
      result.add "the entry document declares `" & module.id & "` at " &
        module.url & ", which the publish directory does not contain"
    if module.builtFrom.len == 0:
      result.add "the entry document declares `" & module.id &
        "` with no provenance, so the page would drop it and report no " &
        "toolchain while serving one"
  # The other direction. A module that is published and not declared is not a
  # broken page — it is 16 MB of upload nothing can reach, which is precisely
  # the "built, deployed, served and never referenced" state that made every
  # BlockTracer session a still frame.
  for asset in declarable:
    let served = "/" & asset.path
    if served notin servedPaths: continue
    var declared = false
    for module in descriptor.modules:
      if module.url == served: declared = true
    if not declared:
      result.add "the publish directory contains " & served &
        ", which the entry document does not declare, so nothing can load it"

proc renderEntryDocument*(descriptor: DeploymentDescriptor): string =
  ## The page. `renderRewriteConfig` points every prefix at this file, and
  ## until now nothing produced it.
  ##
  ## ## Why the document is generated rather than checked in
  ##
  ## The same argument the header makes for `rewritePrefixes` and the asset
  ## manifest, and it is load-bearing twice over here. The document has to name
  ## the two bundles at the paths the manifest declares, and it has to carry
  ## the descriptor of what this particular build delivered — neither of which
  ## a checked-in file can know. A static `index.html` would be a fourth
  ## hand-written copy of the asset list, and the one nobody would think to
  ## update.
  ##
  ## ## The load order is the specification's, and the `defer` is not cosmetic
  ##
  ## `ui.js` boots the platform and then renders — one Nim program, since NS9;
  ## see `rendererBundlePath`. It is `defer`, so the descriptor element is in
  ## the DOM before it runs — `boot()` reads it synchronously and a script that
  ## ran first would find nothing and report a deployment with no toolchain,
  ## which is the failure that looks exactly like a correct empty deployment.
  let json = renderDeploymentDescriptor(descriptor)
  result = """<!DOCTYPE html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CodeTracer &mdash; Noir Studio</title>
<!--
  Generated by viewmodel/platform/web_deployment.nim. Do not edit.

  The JSON below is what THIS deployment placed, measured from the files it
  uploaded. It is read by `host/web_browser.nim` out of the DOM rather than
  fetched, because the development loop is asserted to have zero network
  egress sites (ci/test/noir-studio-signed-out.sh) and a request here would be
  the first.
-->
<script type="application/json" id="""" & deploymentDescriptorElementId &
    """">
""" & json & """
</script>
<link id="theme" rel="stylesheet" href="/""" & rendererThemeStylesPath & """">
<link rel="stylesheet" href="/""" & rendererLoaderStylesPath & """">
<link rel="stylesheet" href="/public/third_party/font-awesome.min.css">
<link rel="stylesheet" href="/public/third_party/vex.css">
<link rel="stylesheet" href="/public/third_party/vex-theme-os.css">
<link rel="stylesheet" href="/public/third_party/golden-layout/dist/css/goldenlayout-base.css">
<link rel="stylesheet" href="/public/third_party/golden-layout/dist/css/themes/goldenlayout-light-theme.css">
<link rel="stylesheet" href="/public/third_party/jstree_default.css">
<link rel="stylesheet" href="/public/third_party/nouislider.css">
<style>
  html, body { margin: 0; height: 100%; }
  /* The two arms' status lines. They are the product's only visible surface
     until the renderer paints, and they are how a FAILED start says so — the
     state this page shipped in reported nothing at all. `#codetracer-renderer`
     is hidden by the renderer itself once a surface is mounted, so a working
     page belongs entirely to the product. */
  #codetracer-boot, #codetracer-renderer {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px; line-height: 1.5; padding: 0.35rem 0.75rem;
    color: #8a8a8a; background: #1e1e1e;
  }
  #codetracer-boot .fault, #codetracer-renderer .fault { color: #f44747; }
</style>
<div id="codetracer-boot">Starting CodeTracer&hellip;</div>
<div id="codetracer-renderer">Starting the renderer&hellip;</div>
<!--
  THE RENDERER'S DOCUMENT, not a placeholder.

  `#dom-root` used to be an empty div, and nothing in `src/frontend/` has ever
  referenced that id — so even a renderer that started had nowhere to paint.
  The ids below are the ones the renderer actually looks up: `ui/layout.nim`
  resolves `ROOT` for the GoldenLayout tree, `ui/welcome_screen.nim` resolves
  `welcomeScreen`, `ui/session_tabs.nim` renders into `menu`, and the IsoNim
  app shell mounts at `isonim-app`. They are `src/frontend/index.html`'s
  skeleton, kept structurally identical on purpose: Noir-Studio.md §1a.1 is
  explicit that the web is a MODE of CodeTracer and that "no pane is invented
  for the web", and two divergent documents would be the first place that stops
  being true.

  They are nested INSIDE `#dom-root` rather than replacing it so that the one
  assertion worth making about this page — that the product mounted — has a
  single subject: `#dom-root` is empty when nothing started and carries the
  IDE when something did.
-->
<div id="dom-root">
  <div id="menu" class="menu"></div>
  <div id="isonim-app"></div>
  <div id="welcomeScreen"></div>
  <div id="root-container">
    <div id="auto-hide-layout-row">
      <div id="auto-hide-strip-left"></div>
      <div id="auto-hide-docked-left">
        <div id="auto-hide-docked-left-content"></div>
        <div id="auto-hide-docked-left-resize" class="auto-hide-docked-resize-handle"></div>
      </div>
      <div id="ROOT">
        <div id="context-menu-container" style="display: none;"></div>
        <div id="fixed-search"></div>
        <div id="session-container-0" class="session-container">
          <section id="main"></section>
        </div>
      </div>
      <div id="auto-hide-docked-right">
        <div id="auto-hide-docked-right-resize" class="auto-hide-docked-resize-handle"></div>
        <div id="auto-hide-docked-right-content"></div>
      </div>
      <div id="auto-hide-strip-right"></div>
    </div>
    <!--
      THE AUTO-HIDE OVERLAY, and its absence is why BUILD could not be SEEN.

      `ui/layout.nim` registers BUILD, PROBLEMS, FIND IN FILES and REQUESTS as
      STANDALONE auto-hide panes: they are not in `default_layout.json`, their
      DOM lives in `#auto-hide-standalone-host` (parked at `left: -9999px`),
      and a user reaches them by clicking a label in the strip. Revealing one
      means `auto_hide.doShowOverlayImpl` reparenting its live element into
      `#auto-hide-overlay-content`.

      This document had the strips and NOT the overlay. So the four labels
      were drawn, clicking one reached `doShowOverlayImpl`, and that proc's
      first act is:

          let overlayEl = document.getElementById(cstring"auto-hide-overlay")
          if overlayEl.isNil:
            cerror "auto_hide: #auto-hide-overlay not found in DOM"
            return

      — a console line and a pane that never appears. Measured: a compile that
      had already painted `codetracer: compiled hello_noir cleanly` into the
      BUILD pane, with the pane still at x = -9999 six seconds later.

      Copied structurally from `src/frontend/index.html`, which is the rule
      this whole skeleton follows and states above: §1a.1 is explicit that the
      web is a MODE of CodeTracer and that "no pane is invented for the web",
      and two divergent documents are the first place that stops being true.
      The docked hosts come with it for the same reason — `pinPanel` and the
      docked sidebar path resolve them by id, and a document carrying half the
      auto-hide surface fails in a different place instead of not at all.
    -->
    <div id="auto-hide-docked-bottom">
      <div id="auto-hide-docked-bottom-resize" class="auto-hide-docked-resize-handle auto-hide-docked-resize-handle-bottom"></div>
      <div id="auto-hide-docked-bottom-content"></div>
    </div>
    <div id="auto-hide-overlay">
      <div id="auto-hide-overlay-resize" class="auto-hide-overlay-resize-handle"></div>
      <div id="auto-hide-overlay-header">
        <span id="auto-hide-overlay-title"></span>
        <div class="auto-hide-overlay-header-buttons">
          <button id="auto-hide-overlay-unpin-btn" title="Unpin (restore to layout)">Unpin</button>
          <button id="auto-hide-overlay-close-btn" title="Close overlay">&#x2715;</button>
        </div>
      </div>
      <div id="auto-hide-overlay-body" style="display:flex; flex:1; min-height:0; overflow:hidden;">
        <div id="auto-hide-overlay-side-tabs"></div>
        <div id="auto-hide-overlay-content"></div>
      </div>
    </div>
    <div id="auto-hide-backdrop"></div>
    <footer>
      <div id="search-results"></div>
      <div id="status"></div>
    </footer>
  </div>
</div>
<!--
  LOAD ORDER, and every position in it is load-bearing.

  1. The third-party bundle FIRST, because `ui.js` reads `monaco` at module
     scope and a browser raises `ReferenceError` — not `undefined` — for a
     global that was never assigned. This is the script whose absence made the
     deployed page blank.
  2. `ui.js` last. It is the ONLY Nim bundle now: it boots the platform, reads
     the descriptor above out of the DOM, and then renders. There used to be a
     `web.js` between these two lines that did the booting, and the renderer
     could not see what it booted — see `rendererBundlePath` for why that was
     structural rather than an oversight.

  All three are `defer`, which preserves document order and keeps a 13 MB
  bundle off the parser's critical path. A `type="module"` would scope them
  more strongly and was measured instead: it makes `ui.js` a `SyntaxError`
  ("Identifier 'debugRepl' has already been declared"), because Nim's JS
  backend emits declarations that are legal only in sloppy mode.

  `ui.js` is still wrapped in an IIFE by `ci/test/web-bundle-assets.sh`, and
  the reason has changed: it is no longer keeping two Nim bundles apart,
  because there are no longer two. It is kept because a bundle that declares
  ~280 top-level names has no business putting them on `window` beside the
  third-party bundle's, and because removing it would be a change with a cost
  and no benefit. What it still costs is unchanged and still worth stating:
  `{.exportc.}` procs meant for a devtools console (`debugCT`, `debugRepl`,
  `readLog`) are not reachable from the global scope in the WEB build.
-->
<script src="/""" & thirdPartyBundlePath & """" defer></script>
<script src="/public/third_party/jstree.min.js" defer></script>
<script src="/""" & rendererBundlePath & """" defer></script>
"""
