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
      ## The bundle's own CONTENT-ADDRESSED assets. Not in §1b.4's table because
      ## they are not an *address* of the product, but they exist and would
      ## otherwise be served under the entry document's class, which would be
      ## wrong in the expensive direction.
      ##
      ## `immutable` here is only correct while the filename carries a digest.
      ## See `ccMutableAsset` for what happened when it did not.
    ccMutableAsset
      ## An asset under `/assets/` whose filename is STABLE across builds.
      ##
      ## ## Measured on ide.codetracer.com and noirstudio.dev, 2026-09-01
      ##
      ## Every file this deployment actually publishes under `/assets/` is in
      ## this class, and all three were being served in `ccStaticAsset`'s:
      ##
      ##     assets/wasm-worker.js
      ##     assets/noir_wasm.wasm
      ##     assets/noir_tracer_wasm.wasm
      ##
      ## `immutable, max-age=31536000` on a stable filename is a promise the
      ## bytes at that URL will never change, and a deploy breaks it every time.
      ## Cloudflare believed it: after deploy `2fb3afa6`, both custom domains
      ## served `assets/wasm-worker.js` at 14150 bytes — the PREVIOUS build —
      ## with `cf-cache-status: HIT` and `age: 131292` (36.5 hours), while the
      ## `pages.dev` origin served the correct 35525. It was still stale an hour
      ## after the deploy, and would have stayed so for a year.
      ##
      ## The product happened to keep working, because that older revision of
      ## the same file still handled `configure`/`start`/`compile`/`trace`. That
      ## is luck, not design: a slightly different older revision is a silently
      ## broken product behind a green deploy.
      ##
      ## THE TWO WASM MODULES CARRY THE SAME RISK AND ESCAPED BY ACCIDENT. They
      ## answered `cf-cache-status: DYNAMIC` — not edge-cached, so always fresh
      ## from origin — for reasons that belong to the CDN and not to us. Nothing
      ## in this file made them safe, so both are in this class too.
      ##
      ## The class is not the end state. It is what is TRUE today: these names
      ## are stable, so the header must revalidate. When the assembly step emits
      ## digests in the filenames, those paths become genuinely content-
      ## addressed and `assetIsContentAddressed` moves them to `ccStaticAsset`
      ## with no further edit here.
      ##
      ## ## 2026-09-02: the assembly step now emits digests, and nothing here
      ## ## was edited to say so
      ##
      ## `web-bundle-assets.sh` renames every file it places under `/assets/`
      ## to `contentAddressedPath(path, sha256(bytes))` and the entry document
      ## carries the resulting URLs. `cacheClassFor` therefore answers
      ## `ccStaticAsset` for all six, and `staticAssetGlobClass` answers
      ## `ccStaticAsset` for the glob — by the same two lines that answered
      ## `ccMutableAsset` the day before. THAT is what this row is for: it is
      ## still reachable, still tested, and still what a stable-named file gets
      ## the moment somebody adds one to the directory.

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
  mutableAssetHeader* = "public, max-age=0, must-revalidate"
    ## The header for a stable-named asset, and `max-age=0` rather than a small
    ## non-zero number on purpose.
    ##
    ## Any positive max-age is a window in which a deploy is invisible, and the
    ## window that matters is the one right after a deploy — exactly when the
    ## bytes changed. `must-revalidate` alone does not close it: it governs what
    ## a cache may do once the entry is ALREADY stale, so `max-age=14400,
    ## must-revalidate` (which `/ui.js` carries) still permits four hours of the
    ## previous build.
    ##
    ## What this costs is one conditional request per asset per load, and what
    ## it saves is the body: these files have strong ETags, so a warm cache pays
    ## a round trip and a ~300-byte `304`, not 14 MB. That is the right trade
    ## for a file whose staleness silently disables the compiler.
    ##
    ## It is NOT the trade for a content-addressed file, which is why
    ## `staticAssetHeader` still exists and still says `immutable`: a digest in
    ## the name makes the promise true and the round trip pure waste.

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

proc assetIsContentAddressed*(path: string): bool =
  ## Does this asset's FILENAME carry a digest, so that `immutable` is true?
  ##
  ## This is the precondition the whole `ccStaticAsset` row rests on, and until
  ## 2026-09-01 it was written only in prose — this file's own comments said
  ## `/assets/` was "content-addressed" and the unit test selected the class
  ## with `/assets/app.9f2b1c.js`, a filename no assembly step has ever
  ## produced. Every real published asset has a stable name, so the class was
  ## being validated on a fictional address while the three real ones went
  ## unchecked. Making the predicate a FUNCTION is the point: it can be asked
  ## about the paths a deployment actually ships.
  ##
  ## The shape recognised is `<name>.<digest>.<ext>` with a digest of at least
  ## six hex characters — what every bundler emits and what
  ## `/assets/app.9f2b1c.js` was pretending to be. A bare `name.ext` is not
  ## content-addressed, and neither is `noir_wasm.wasm`.
  let slash = path.rfind('/')
  let name = if slash >= 0: path[slash + 1 .. ^1] else: path
  let parts = name.split('.')
  # Fewer than three parts cannot carry a digest BETWEEN a stem and an
  # extension, which is the only position that survives a rename.
  if parts.len < 3: return false
  for i in 1 ..< parts.len - 1:
    let segment = parts[i]
    if segment.len < 6: continue
    var allHex = true
    for c in segment:
      if c notin HexDigits:
        allHex = false
        break
    if allHex: return true
  false

const assetDigestLength* = 16
  ## How many hex characters of the content digest go into a filename.
  ##
  ## Sixteen, not sixty-four. The property that has to hold is that two
  ## different byte sequences do not collide on one URL, and 64 bits of SHA-256
  ## gives that with room to spare over a set of six files; the rest is path
  ## length in every log, header and manifest that carries it. It is well above
  ## `assetIsContentAddressed`'s six-character floor, which is deliberate: the
  ## predicate and the producer must not be the same number, or a change to one
  ## silently becomes a change to the other.

proc contentAddressedPath*(path, digest: string): string =
  ## `assets/wasm-worker.js` + a digest -> `assets/wasm-worker.<digest>.js`.
  ##
  ## THE ONE PLACE THE NAME IS FORMED, and it is here rather than in the shell
  ## for the reason this module's header gives about every other list it owns.
  ## `assetIsContentAddressed` decides what earns `immutable`; if the assembly
  ## step spelled the name itself, the producer and the predicate would be two
  ## descriptions of one convention with nothing comparing them — which is
  ## exactly how `/assets/app.9f2b1c.js` came to be the only address the cache
  ## class was ever tested on, a filename no assembly step has ever produced.
  ## `ci/test/web_asset_name.nim` calls this and refuses to print a name the
  ## predicate would reject, so the example and the output cannot diverge.
  ##
  ## The digest goes BETWEEN the stem and the final extension rather than at the
  ## end, because the extension is what a static host reads to choose a
  ## `Content-Type` — `db_backend_bg.wasm.<digest>` would be served
  ## `application/octet-stream` and `WebAssembly.instantiateStreaming` refuses
  ## it by name.
  ##
  ## Returns "" for a digest that could not make the name content-addressed, so
  ## a caller that forgot to check gets an obviously broken path rather than a
  ## plausible one that quietly re-earns `immutable` on a stable name.
  if digest.len < assetDigestLength: return ""
  let short = digest[0 ..< assetDigestLength]
  for c in short:
    if c notin HexDigits: return ""
  let dot = path.rfind('.')
  let slash = path.rfind('/')
  # No extension, or a dot that belongs to a directory rather than to the
  # filename: there is no "between the stem and the extension" to insert into.
  if dot <= slash + 1: return ""
  result = path[0 ..< dot] & "." & short & path[dot .. ^1]

proc contentAddressedStem*(path: string): string =
  ## The path a content-addressed name was derived from — the inverse of
  ## `contentAddressedPath`, and `path` unchanged when it carries no digest.
  ##
  ## Needed because every check that knows a file by its MANIFEST name has to
  ## be able to find it under its published one. That is the trap the deploy
  ## checks were warned about: a digest in the name is precisely where a
  ## path-deriving check stops matching, and it stops matching by finding
  ## nothing, which reads as "nothing wrong".
  let slash = path.rfind('/')
  let dir = if slash >= 0: path[0 .. slash] else: ""
  let name = if slash >= 0: path[slash + 1 .. ^1] else: path
  let parts = name.split('.')
  if parts.len < 3: return path
  for i in 1 ..< parts.len - 1:
    let segment = parts[i]
    if segment.len < 6: continue
    var allHex = true
    for c in segment:
      if c notin HexDigits:
        allHex = false
        break
    if allHex:
      var kept: seq[string]
      for j in 0 ..< parts.len:
        if j != i: kept.add parts[j]
      return dir & kept.join(".")
  path

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
    # `immutable` follows the DIGEST, not the directory. Serving a stable name
    # under a year-long `immutable` is what pinned a 36-hour-old wasm worker on
    # both custom domains through a successful deploy; see `ccMutableAsset`.
    return if assetIsContentAddressed(path): ccStaticAsset else: ccMutableAsset
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
#                wasm modules and the replay engine are this because they are
#                ~16 MB, ~4.6 MB and ~18 MB: a bundled copy inflates by a third
#                as base64 AND must be parsed as JavaScript source before the
#                first paint, for capabilities most sessions never invoke.
#
#                WHAT THEY ARE NOT, YET. This paragraph used to end "fetched,
#                they are `ccImmutable` and cached indefinitely", and that
#                stopped being true on 2026-09-01: `immutable` follows the
#                DIGEST, none of these filenames carries one, and
#                `cacheClassFor` therefore answers `ccMutableAsset` —
#                `max-age=0, must-revalidate` — for all five. The delivery
#                decision still holds on its own terms (bytes off the
#                first-paint path, fetched only when the capability is used),
#                but the caching half of the argument is currently unearned,
#                and `unhashedStaticAssets()` names exactly which files owe
#                it. Digested filenames from the assembly step are what would
#                pay it back, and `cacheClassFor` already answers
#                `ccStaticAsset` the moment they appear.
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

  FetchConsumer* = enum
    ## WHICH run-time consumer fetches a `damFetched` asset.
    ##
    ## `damFetched` used to have exactly one meaning, because it had exactly
    ## two members: "a Noir wasm module the bare-ABI worker `load()`s by id".
    ## `noir_wasm_modules.deliverableModuleIds()` IS `fetchedRuntimeAssets()`,
    ## and `web-bundle-assets.sh`'s Step 6 greps `load('<id>')` in
    ## `wasm_worker_browser.js` for every fetched row — so a third fetched
    ## asset would have joined the Noir wasm registry by arithmetic, and the
    ## page would have declared `nargo` over a module that is not a Noir
    ## module and has no `nv_*` / `ct_*` ABI at all.
    ##
    ## The replay engine is fetched for the same reasons the Noir modules are
    ## (18 MB, wanted by a minority of sessions, `immutable` once fetched) and
    ## belongs to a different consumer: it is a wasm-bindgen module driven
    ## from its own worker. So the delivery decision and the consumer are two
    ## fields rather than one.
    fcNotFetched
      ## Not `damFetched`. The default, so every non-fetched row is unchanged.
    fcNoirWasmWorker
      ## `wasm_worker_browser.js` resolves it by id from the `configure`
      ## message and instantiates it against the bare `nv_*` / `ct_*` ABI.
    fcReplayEngine
      ## `replay-worker.js` instantiates it through wasm-bindgen glue and
      ## then speaks DAP over `postMessage`.

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
    fetchedBy*: FetchConsumer
      ## Meaningful only for `damFetched`, and `fetchedDeclaresItsConsumer()`
      ## holds the two in agreement in both directions.

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
  wasmWorkerAssetId* = "wasm-worker"
    ## Exported because three places must agree on it: `webRuntimeAssets`,
    ## the assembly step's descriptor row, and `host/web_browser.nim`'s
    ## `assetUrl` lookup. A literal spelled at the lookup site is how an id
    ## drifts into a URL that is silently "" — which reads, downstream, as a
    ## deployment that ships no toolchain.
  wasmWorkerScriptPath* = staticAssetPrefix[1 .. ^1] & "wasm-worker.js"
    ## The name the assembly step places the worker under BEFORE digesting it.
    ## No deployment serves this address; see `PublishedAsset`.
  noirCompilerModuleId* = "noir-compiler"
  noirTracerModuleId* = "noir-tracer"
  noirCompilerWasmPath* = staticAssetPrefix[1 .. ^1] & "noir_wasm.wasm"
  noirTracerWasmPath* = staticAssetPrefix[1 .. ^1] & "noir_tracer_wasm.wasm"
  avmTranspilerModuleId* = "avm-transpiler"
  avmTranspilerWasmPath* = staticAssetPrefix[1 .. ^1] & "avm_transpiler_wasm.wasm"

  # THE REPLAY ENGINE. Three files, and they are the Studio's OWN copies.
  #
  # The same bytes are already published at `/worker.js` and `/pkg/*` by the
  # staging step, because BlockTracer fetches them cross-origin from this
  # deployment and the deploy workflow asserts they have not moved. Those
  # paths stay exactly where they are: this repository's deploy breaking
  # another one's is the failure that check exists for.
  #
  # So the Studio declares its own copies under `/assets/` rather than
  # pointing the manifest at `/pkg/`. That is not duplication for its own
  # sake — it is what keeps every existing rule true at once. A manifest row
  # under `/pkg/` would be served with the entry document's 60-second TTL
  # (`cacheClassFor` maps exactly one prefix to `ccStaticAsset`), and making
  # `/pkg/*` immutable instead would pin a non-content-addressed 18 MB engine
  # in every CDN edge and browser cache for a year — on the path another
  # product fetches. The cost of the copy is upload bytes in CI; a visitor
  # fetches one or the other, never both.
  replayWorkerScriptPath* = staticAssetPrefix[1 .. ^1] & "replay-worker.js"
  replayEngineModuleId* = "replay-engine"
  replayEngineGlueId* = "replay-engine-glue"
  replayWorkerModuleId* = "replay-worker"
  replayEngineWasmPath* = staticAssetPrefix[1 .. ^1] & "db_backend_bg.wasm"
  replayEngineGluePath* = staticAssetPrefix[1 .. ^1] & "db_backend.js"

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
      id: wasmWorkerAssetId, path: wasmWorkerScriptPath, mode: damAsset,
      required: true,
      absenceBehaviour: ""),
    RuntimeAsset(
      id: noirCompilerModuleId, path: noirCompilerWasmPath, mode: damFetched,
      required: false, fetchedBy: fcNoirWasmWorker,
      absenceBehaviour:
        "Noir compilation is unavailable and `nargo compile` is reported as " &
        "having no wasm build in this deployment, by name, rather than " &
        "failing part-way through a run"),
    RuntimeAsset(
      id: noirTracerModuleId, path: noirTracerWasmPath, mode: damFetched,
      required: false, fetchedBy: fcNoirWasmWorker,
      absenceBehaviour:
        "a compiled Noir program cannot be traced in the tab, so replay is " &
        "offered only for recordings produced elsewhere"),
    RuntimeAsset(
      id: replayWorkerModuleId, path: replayWorkerScriptPath, mode: damAsset,
      required: false,
      absenceBehaviour:
        "a trace produced in the tab can be inspected as counts but not " &
        "STEPPED THROUGH: with no worker to instantiate the replay engine " &
        "in, the session reports that this deployment ships no engine " &
        "rather than opening a debugger that answers nothing"),
    RuntimeAsset(
      id: replayEngineGlueId, path: replayEngineGluePath, mode: damFetched,
      required: false, fetchedBy: fcReplayEngine,
      absenceBehaviour:
        "the replay engine cannot be instantiated — the wasm is bytes and " &
        "this is the wasm-bindgen glue that imports them — so replay is " &
        "reported as unavailable rather than failing inside " &
        "`WebAssembly.compileStreaming`"),
    RuntimeAsset(
      id: replayEngineModuleId, path: replayEngineWasmPath, mode: damFetched,
      required: false, fetchedBy: fcReplayEngine,
      absenceBehaviour:
        "a trace can be produced in the tab and not replayed in it; the " &
        "session says so by name instead of opening on an empty timeline"),
    RuntimeAsset(
      id: avmTranspilerModuleId, path: avmTranspilerWasmPath, mode: damFetched,
      required: false, fetchedBy: fcNoirWasmWorker,
      absenceBehaviour:
        "an Aztec contract compiled in the tab cannot be turned into AVM " &
        "bytecode, so `avm-transpiler transpile` is reported as having no " &
        "wasm build in this deployment and a contract stops at the artifact")]

proc requiredRuntimeAssets*(): seq[RuntimeAsset] =
  for asset in webRuntimeAssets():
    if asset.required: result.add asset

proc fetchedRuntimeAssets*(): seq[RuntimeAsset] =
  ## Everything fetched at run time rather than at load, whoever fetches it.
  ##
  ## This is the DELIVERY question, and it is the one the deploy guard and the
  ## entry document's `modules[]` ask: a fetched file present in the publish
  ## tree but not declared in the served page is a defect, because nothing at
  ## run time could have found its URL. It is NOT the question "which ids does
  ## the Noir wasm worker resolve" — that is `noirWasmModuleAssets`, and the
  ## two were the same list only for as long as the engine was undeclared.
  for asset in webRuntimeAssets():
    if asset.mode == damFetched: result.add asset

proc fetchedBy*(consumer: FetchConsumer): seq[RuntimeAsset] =
  ## The fetched assets one run-time consumer resolves.
  for asset in webRuntimeAssets():
    if asset.mode == damFetched and asset.fetchedBy == consumer:
      result.add asset

proc noirWasmModuleAssets*(): seq[RuntimeAsset] =
  ## The modules `wasm_worker_browser.js` receives in its `configure` message
  ## and instantiates against the bare `nv_*` / `ct_*` ABI.
  fetchedBy(fcNoirWasmWorker)

proc replayEngineAssets*(): seq[RuntimeAsset] =
  ## The wasm-bindgen engine `replay-worker.js` instantiates. Two files, and
  ## both or neither: the glue without the wasm imports bytes that are not
  ## there, and the wasm without the glue is 18 MB nothing can call into.
  fetchedBy(fcReplayEngine)

proc fetchedWithoutConsumer*(): seq[string] =
  ## Every row where the delivery decision and the consumer disagree.
  ##
  ## Asserted `.len == 0` in both directions, and that is the whole point of
  ## splitting them: a new `damFetched` row that forgot to say who fetches it
  ## would default to `fcNotFetched` and vanish from every consumer's list
  ## while still being declared, placed and served — an asset nothing loads,
  ## which is this repository's signature defect. A row that names a consumer
  ## without being fetched is the same mistake pointing the other way.
  for asset in webRuntimeAssets():
    if asset.mode == damFetched and asset.fetchedBy == fcNotFetched:
      result.add asset.id
    elif asset.mode != damFetched and asset.fetchedBy != fcNotFetched:
      result.add asset.id

proc undeclaredAbsences*(): seq[string] =
  ## Every optional asset that does not say what its absence costs. The
  ## assertion is `.len == 0` over this, mirroring
  ## `capabilities.undeclaredDegradations` — a manifest that lets an optional
  ## asset in without a consequence is a table that has stopped describing the
  ## product.
  for asset in webRuntimeAssets():
    if not asset.required and asset.absenceBehaviour.len == 0:
      result.add asset.id

proc declaredStaticAssetStems*(): seq[string] =
  ## Every `/assets/` path the MANIFEST declares, as the address a browser would
  ## request if the file were published under its manifest name.
  ##
  ## These are stems, not addresses: the assembly step renames each of them to
  ## `contentAddressedPath(path, sha256(bytes))` before publishing, so no
  ## deployment serves any of these strings. It is the INTENT half — which files
  ## a bundle must carry — and it is deliberately not called
  ## `publishedStaticAssets` any more, because that name is now the FACT half
  ## and reads a descriptor. Confusing the two is what let the cache class be
  ## derived from a list of names nothing served.
  let prefix = staticAssetPrefix[1 .. ^1]
  for asset in webRuntimeAssets():
    if asset.path.len >= prefix.len and asset.path[0 ..< prefix.len] == prefix:
      result.add "/" & asset.path

proc headerFor*(class: CacheClass): string =
  case class
  of ccEntryDocument: entryDocumentHeader
  of ccImmutable: immutableHeader
  of ccPointer: pointerHeader
  of ccStaticAsset: staticAssetHeader
  of ccMutableAsset: mutableAssetHeader

proc deploymentContractWithAssetClass(origin: string;
                                      assetClass: CacheClass
                                     ): DeploymentContract =
  ## The contract, given the class the `/assets/*` glob has been DERIVED to
  ## carry. `deploymentContract` below is the only caller and supplies that
  ## class from the deployment's own published set; the split exists only
  ## because `DeploymentDescriptor` is declared further down this file.
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
    CacheRule(pattern: staticAssetPrefix & "*",
              class: assetClass,
              headerValue: headerFor(assetClass)),
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
  result.add "# Noir-Studio.md §1b.4 — cache classes keyed on path prefix.\n"
  result.add "# Most specific first: the first matching rule wins.\n"
  result.add "# `immutable` appears only on content-addressed paths; see\n"
  result.add "# `ccMutableAsset` in web_deployment.nim for the deploy it cost.\n"
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

  PublishedAsset* = object
    ## One NON-FETCHED file a particular deployment placed under `/assets/`,
    ## at the name it was actually published under.
    ##
    ## ## Why the worker scripts needed a descriptor row and the modules did not
    ##
    ## A `damFetched` module was already indirected: `modules[].url` is data the
    ## page reads, so giving the file a digest changed a string in a JSON blob
    ## and nothing else. The two `damAsset` worker scripts were not. Their URLs
    ## were Nim constants — `"/" & wasmWorkerScriptPath` in
    ## `host/web_browser.nim` and `"/" & replayWorkerScriptPath` in
    ## `ui/web_replay_host.nim` — and a constant cannot name a file whose name
    ## depends on its bytes. So they get the same treatment the modules already
    ## had: the deployment says where it put them, and the product asks.
    ##
    ## They are a separate field from `modules` rather than more rows in it,
    ## because `modules` has a meaning that several readers depend on:
    ## `declaredModuleUrls` is what reaches a worker's `configure` message, and
    ## `deployGuardDefects` grades it against `fetchedRuntimeAssets()`. A worker
    ## script in that list would be handed to itself as a module to instantiate.
    id*: string
      ## A `webRuntimeAssets()` asset id.
    url*: string
      ## Root-relative, with the digest in the name.
    bytes*: int
      ## Measured from the file, like `DeployedModule.bytes` and for the same
      ## reason.

  DeploymentDescriptor* = object
    origin*: string
    revision*: string
      ## The codetracer commit the bundle was built from, SHORTENED for a
      ## human to read — it is what a module's `builtFrom` clause carries.
      ## `commit` beside it is the same fact at full width; see there for why
      ## both exist.
    commit*: string
      ## The codetracer commit the bundle was built from, as the full 40-hex
      ## object name, or "" when the build did not know it.
      ##
      ## NOT a duplicate of `revision`, and the difference is the whole reason
      ## `/build-id.txt` exists. `revision` is an abbreviation, and an
      ## abbreviation is a string you cannot hand to `git` without hoping: it
      ## is not a name a `git cat-file` accepts across every repository, it
      ## cannot be compared for equality against a workflow's `github.sha`
      ## without truncating one side, and truncation is precisely where a
      ## probe stops being able to tell two builds apart. The published
      ## identity carries the full name so that "is the fix in?" is an
      ## equality test rather than a prefix guess.
    branch*: string
      ## The branch the deploy published from, or "" when unknown. Two
      ## deployments of this product exist at once (`cloud` is production;
      ## anything else is a preview), and a bare SHA does not say which one is
      ## being looked at.
    modules*: seq[DeployedModule]
    assets*: seq[PublishedAsset]
      ## The published, non-fetched `/assets/` files. See `PublishedAsset`.
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
  var assets = newJArray()
  for asset in descriptor.assets:
    assets.add %*{
      "id": asset.id,
      "url": asset.url,
      "bytes": asset.bytes}
  var languageOrigins = newJArray()
  for entry in descriptor.languageOrigins:
    languageOrigins.add %*{
      "origin": entry.origin,
      "language": entry.language}
  jsonStringForHtml(%*{
    "origin": descriptor.origin,
    "revision": descriptor.revision,
    "commit": descriptor.commit,
    "branch": descriptor.branch,
    "modules": modules,
    "assets": assets,
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
  # ABSENT IS "", NOT AN ERROR. A document rendered before this field existed
  # is still a working deployment; it simply cannot say which commit it is, and
  # `buildIdentityOf` answers `unknown` for it rather than inventing one.
  result.commit = parsed{"commit"}.getStr
  result.branch = parsed{"branch"}.getStr
  # EACH SECTION IS PARSED INDEPENDENTLY, and that is a fix rather than a
  # rearrangement. This used to `return` when `modules` was absent or not an
  # array, which silently took `languageOrigins` — and now `assets` — with it. A
  # deployment that ships no toolchain is supported and documented; one that
  # also loses its host map and its worker URLs because of that is not, and the
  # symptom would have been a working product at the generic entry point with
  # no worker, which is three defects wearing one face.
  let modules = parsed{"modules"}
  if not modules.isNil and modules.kind == JArray:
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

  let assets = parsed{"assets"}
  if not assets.isNil and assets.kind == JArray:
    for entry in assets:
      if entry.kind != JObject: continue
      let asset = PublishedAsset(
        id: entry{"id"}.getStr,
        url: entry{"url"}.getStr,
        bytes: entry{"bytes"}.getInt)
      # No provenance clause here, unlike a module: a worker script is this
      # repository's own file and `registrableModules` never sees it. An id and
      # a URL are exactly what makes it usable, and a row missing either is
      # dropped for the same reason a half-declared module is — a URL the page
      # would `new Worker("")` on is worse than a stated absence.
      if asset.id.len == 0 or asset.url.len == 0: continue
      result.assets.add asset

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

proc assetUrl*(descriptor: DeploymentDescriptor; id: string): string =
  ## Where THIS deployment put a non-fetched asset, or "" if it declared none.
  ##
  ## The empty string is a real answer and callers must treat it as one. It
  ## means the deployment did not publish that file, and the honest response is
  ## the asset's `absenceBehaviour` — not `new Worker("")`, which throws a
  ## `SyntaxError` naming nothing, and not a fall back to the manifest stem,
  ## which would request a URL no deploy has served since digests landed and
  ## get the SPA entry document at 200 `text/html` from Cloudflare Pages for
  ## its trouble.
  for asset in descriptor.assets:
    if asset.id == id: return asset.url
  ""

proc declaresNoirWasmWorker*(descriptor: DeploymentDescriptor): bool =
  ## Does this deployment publish the worker the Noir modules are instantiated
  ## in? A module is bytes; this is the thing that runs them.
  assetUrl(descriptor, wasmWorkerAssetId).len > 0

proc noirRunnableModules*(descriptor: DeploymentDescriptor): seq[DeployedModule] =
  ## The declared modules a tab can actually RUN, which is not the same list as
  ## the ones it was told about.
  ##
  ## ## The implication content-addressed filenames broke
  ##
  ## `wasmWorkerScriptPath` was a compile-time constant, so "the descriptor
  ## names modules" ENTAILED "there is a worker to run them in": the second
  ## fact had no way to be false on its own. The worker is now published under
  ## a content digest and its URL is a descriptor row like any other, so a
  ## document can name two Noir modules and no worker at all.
  ##
  ## Ungated, that deployment reports `toolchain=nargo:compile+trace` on its
  ## boot line — `describeToolchain` reads the registry, and the registry is
  ## built from the modules — while `browserWasmHost` answers `noWasmModules()`
  ## and every run refuses. `host/web_browser.nim`'s header forbids exactly
  ## that: "declaring `nargo` over modules that were never placed would put
  ## `capProcessSpawn` back on a profile whose every run fails". This is that
  ## defect reached from the other side — the modules ARE placed, and the thing
  ## that runs them is not.
  ##
  ## ## Why the rule is here and not at the call site
  ##
  ## Because `host/web_browser.nim` is compiled by no test. It is a browser
  ## module — `host-instantiations` builds it and cannot run it — so a rule
  ## written there is a rule nothing checks, which is this repository's
  ## signature defect and the reason that file once sat unparseable on `dev`
  ## for days. Here it is compiled and asserted on both backends by
  ## `test_platform_web.nim`, and `deliveredModulesFrom` is a one-line map over
  ## it.
  ##
  ## Scoped to the NOIR worker deliberately. The replay engine is fetched by a
  ## different consumer with its own script (`replay-worker`), and
  ## `ui/web_replay_host.nim` refuses by name when that one is undeclared. The
  ## engine's availability is not this worker's business, and
  ## `declaredModuleUrls` — which carries the URLs into a `configure` message —
  ## is deliberately NOT gated, because a worker that exists must still be told
  ## about everything the deployment published.
  if not declaresNoirWasmWorker(descriptor): return @[]
  descriptor.modules

proc publishedUrl*(descriptor: DeploymentDescriptor; id: string): string =
  ## Where this deployment put an asset, whichever half of the descriptor it
  ## travels in, or "" if it declared none.
  ##
  ## `assetUrl` and `declaredModuleUrls` are the two halves and both have
  ## callers that must NOT be given the other's rows — a worker script handed to
  ## `configure` would be instantiated as a module. This is for the readers that
  ## genuinely do not care which kind a file is, which is every check that asks
  ## "where was this published".
  for asset in descriptor.assets:
    if asset.id == id: return asset.url
  for module in descriptor.modules:
    if module.id == id: return module.url
  ""

proc publishedStaticAssets*(descriptor: DeploymentDescriptor): seq[string] =
  ## Every `/assets/` address THIS deployment actually published, from both
  ## halves of the descriptor: the fetched modules and the worker scripts.
  ##
  ## This is the FACT list. It replaces a same-named function that read
  ## `webRuntimeAssets()` — the manifest — and the difference is the whole
  ## repair. A digest cannot be a compile-time constant, so a cache class
  ## derived from compile-time paths could only ever describe a deployment
  ## whose filenames were stable. It described one for a year.
  let prefix = staticAssetPrefix
  proc underAssets(url: string): bool =
    url.len >= prefix.len and url[0 ..< prefix.len] == prefix
  for module in descriptor.modules:
    if underAssets(module.url): result.add module.url
  for asset in descriptor.assets:
    if underAssets(asset.url): result.add asset.url

proc unhashedStaticAssets*(descriptor: DeploymentDescriptor): seq[string] =
  ## The published `/assets/` addresses that carry no digest, and therefore may
  ## not be served `immutable`.
  ##
  ## A value rather than a boolean so a failing assertion can NAME the files.
  ## Its six members on 2026-09-01 were the files the staleness was found on;
  ## it is empty for a deployment the current assembly step produced, and the
  ## test that says so asserts the count of what it looked at, because an empty
  ## answer from an empty input is the failure this whole area keeps finding.
  for path in publishedStaticAssets(descriptor):
    if not assetIsContentAddressed(path): result.add path

proc staticAssetGlobClass*(descriptor: DeploymentDescriptor): CacheClass =
  ## The class the single `/assets/*` rule may carry, DERIVED from the assets
  ## this deployment actually published.
  ##
  ## Cloudflare's `_headers` matches by glob and cannot ask whether a filename
  ## has a digest, so one rule must cover the whole directory — and a rule that
  ## covers a mixed directory has to be correct for its weakest member. Deriving
  ## it means the day the assembly step started emitting digests the glob became
  ## `immutable` on its own, and the day someone adds a stable-named file to a
  ## hashed directory it stops being `immutable` on its own. Neither is a
  ## decision anybody has to remember to make, and neither has been made by hand
  ## here: the body below is the two lines it has always been.
  ##
  ## ## The empty deployment does not earn `immutable`, and that is not pedantry
  ##
  ## "Every published asset carries a digest" is a universal quantification, and
  ## it is TRUE of a deployment that published nothing. Without the first
  ## clause, a descriptor that lost its `assets` array — a rename, a parse
  ## failure, an assembly step that placed no worker — would flip `/assets/*` to
  ## a year of `immutable` on the strength of having no evidence, which is the
  ## precise shape of the check that reported `ok: 0/0 published files match`
  ## and exited 0. `immutable` is a promise about bytes; it has to be paid for
  ## by bytes that exist.
  if publishedStaticAssets(descriptor).len == 0: return ccMutableAsset
  if unhashedStaticAssets(descriptor).len > 0: ccMutableAsset else: ccStaticAsset

proc deploymentContract*(origin: string;
                         descriptor: DeploymentDescriptor
                        ): DeploymentContract =
  ## The whole contract, for a named origin and a particular published set.
  ##
  ## No default for either — see the header for the origin, and
  ## `staticAssetGlobClass` for the descriptor. A default descriptor would be
  ## the empty one, and the empty one is exactly the input whose answer must not
  ## be trusted; making it a parameter forces every caller, including every
  ## test, to say which deployment's cache table it is talking about.
  deploymentContractWithAssetClass(origin, staticAssetGlobClass(descriptor))

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
  # THE SAME TWO QUESTIONS FOR THE WORKER SCRIPTS. They are `damAsset`, so they
  # are not in `modules[]` and were not graded here at all — which was safe only
  # for as long as their URLs were constants the guard could not disagree with.
  # Now that a deployment says where it put them, it can say something false.
  for asset in descriptor.assets:
    var known = false
    for declarableAsset in webRuntimeAssets():
      if declarableAsset.mode == damAsset and declarableAsset.id == asset.id:
        known = true
    if not known:
      result.add "the entry document declares asset `" & asset.id &
        "`, which the runtime asset manifest does not name"
    if asset.url notin servedPaths:
      result.add "the entry document declares `" & asset.id & "` at " &
        asset.url & ", which the publish directory does not contain"

  # EVERY DECLARED `/assets/` URL CARRIES A DIGEST, checked by name rather than
  # left to be absorbed by the header table.
  #
  # `staticAssetGlobClass` already answers `ccMutableAsset` for a set with one
  # stable name in it, so the deployment would be CORRECT — and 34 MB slower on
  # every page load, silently, with nothing saying which file cost it. A guard
  # sentence naming the file is the difference between a downgrade somebody
  # fixes and a downgrade nobody notices.
  for path in unhashedStaticAssets(descriptor):
    result.add "the entry document publishes " & path &
      " under a stable name, so `/assets/*` must drop to `" &
      mutableAssetHeader & "` for the whole directory — every asset beside it " &
      "pays for this one"

  # The other direction, for both kinds. A file that is published and not
  # declared is not a broken page — it is 16 MB of upload nothing can reach,
  # which is precisely the "built, deployed, served and never referenced" state
  # that made every BlockTracer session a still frame.
  #
  # MATCHED THROUGH `contentAddressedStem` AND NOT BY EQUALITY, which is the
  # correction digests forced. This loop used to ask whether `"/" & asset.path`
  # was served; once the assembly step renames every file it places, that string
  # is served by no deployment, so the `continue` fired for every asset and the
  # check quietly stopped running while still passing. A digest in the name is
  # exactly where a path-deriving check stops matching.
  var declaredUrls: seq[string]
  for module in descriptor.modules: declaredUrls.add module.url
  for asset in descriptor.assets: declaredUrls.add asset.url
  for asset in webRuntimeAssets():
    if asset.mode notin {damFetched, damAsset}: continue
    let stem = "/" & asset.path
    for served in servedPaths:
      if contentAddressedStem(served) != stem: continue
      if served notin declaredUrls:
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
  more strongly and was measured instead: it made `ui.js` a `SyntaxError`
  ("Identifier 'debugRepl' has already been declared").

  That was read at the time as "Nim's JS backend emits declarations that are
  legal only in sloppy mode".  It was narrower and worse than that: TWO
  `{.exportc.}` procs were named `debugRepl` — `renderer.debugRepl` and
  `services/debugger_service.debugRepl` — and `exportc` fixes the emitted
  name, so the bundle carried two top-level `function debugRepl`
  declarations.  Module scope merely made a pre-existing collision loud.  In
  sloppy mode it was silent and therefore worse: the last declaration won, so
  the service method was unreachable in EVERY build, Electron included.  The
  `exportc` is gone from the service method and
  `ci/test/js-bundle-name-uniqueness.sh` fails on a duplicate name now.
  Whether `type="module"` is viable has NOT been re-measured since.

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

# ---------------------------------------------------------------------------
# THE PUBLISHED BUILD IDENTITY — `/build-id.txt`
#
# ## The question this answers, and why nothing could answer it
#
# "Which revision is noirstudio.dev serving?" had no cheap answer. Everything
# the deployment already published names a BUILD without naming a COMMIT: the
# hashed asset names (`assets/db_backend.7c9b88e3….js`) identify bytes and no
# revision, and `revision` in the entry document is an abbreviation buried in a
# JSON island inside 9 KB of HTML. So the answer was assembled by reading
# workflow logs and comparing asset filenames — an inference chain with several
# places to be wrong, and this campaign has been wrong in most of them: verdicts
# that could not name the artefact they measured, and three different
# host-discriminators proposed in one brief because nobody could ask a host what
# it was.
#
# ## Why a file and not just the descriptor
#
# The descriptor is for the PAGE; this is for a human with `curl` and for a
# script. One line, one request, no HTML parsing, no JSON:
#
#     $ curl https://noirstudio.dev/build-id.txt
#     builtFrom 7ae43783f001eb832cab9996934afd08449ea0bc branch=cloud …
#
# ## Why blocktracer's exact format
#
# BlockTracer publishes this file already, at the same path, with the same
# leading `builtFrom <sha>` and `branch=<name>`. Matching it is not deference:
# it means ONE probe reads both products, so an operator does not need to know
# which repository built the page in order to ask what built it. Inventing a
# second spelling of the same fact would put the cost of the difference on
# every future reader.
#
# ## Why the SHA is 40 hex characters and the check says so
#
# Cloudflare Pages answers an absent path with the SPA fallback: `/build-id.txt`
# on a deployment that does not publish it returns **200 OK, `text/html`, the
# entry document**. A gate that fetched the path and asserted a 200 would
# therefore pass against every deployment that has never heard of this file —
# it would be a check that cannot fail, which is the exact failure mode this
# repository keeps finding. So the assertion is on the CONTENT: the body must
# parse as this one-line form and name a full object name. `parseBuildId`
# returns the empty identity for an HTML document, and `buildIdDefects` says so
# in a sentence.
# ---------------------------------------------------------------------------

type
  BuildIdentity* = object
    ## What a deployment says it was built from. Every field may be "" — an
    ## identity that cannot be established is reported as unknown rather than
    ## guessed, for the reason `parseDeploymentDescriptor` gives about
    ## half-declared modules.
    commit*: string
      ## The full 40-hex object name. "" when unknown or malformed.
    branch*: string
    project*: string
      ## Which Pages project served it. BlockTracer's file carries this because
      ## one repository deploys several; ours carries it for symmetry and
      ## because `web-codetracer` serving `noirstudio.dev` is not obvious.
    runId*: string
    runAttempt*: string
    builtAt*: string
      ## ISO-8601 UTC, as the workflow stamped it.

const
  buildIdPath* = "build-id.txt"
    ## Relative to the publish root, like `entryDocumentPath`.
  buildIdAddress* = "/" & buildIdPath
    ## The URL, which is the whole interface. Exported because four things must
    ## agree on it: this renderer, `ci/test/web_deployment_render.nim`,
    ## `ci/test/verify-build-id.sh`, and BlockTracer's deploy — the last one by
    ## having chosen it first.

proc isCommitName*(text: string): bool =
  ## Exactly 40 hex characters: a full git object name and nothing else.
  ##
  ## NOT `len >= 7 and all-hex`, which would accept an abbreviation — and an
  ## abbreviation is what makes "does this host carry the fix?" a prefix guess
  ## instead of an equality test. Not case-normalised either: git writes lower
  ## case, and a build stamping upper case is a build doing something
  ## unexplained, so both are accepted for reading and `renderBuildId` writes
  ## what it was given.
  if text.len != 40: return false
  for c in text:
    if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return false
  true

proc renderBuildId*(identity: BuildIdentity): string =
  ## The file, as BlockTracer spells it.
  ##
  ## `builtFrom <sha>` first and unkeyed, because that is the form the sibling
  ## already publishes and the form `awk '{print $2}'` reads. The keyed clauses
  ## follow in a fixed order; an empty one is OMITTED rather than emitted as
  ## `key=`, so a reader never has to distinguish "absent" from "present and
  ## empty", and a local build with no run id is a shorter line rather than a
  ## line full of blanks.
  ##
  ## Single trailing newline: this is a text file people `cat`.
  result = "builtFrom " & identity.commit
  if identity.branch.len > 0: result.add " branch=" & identity.branch
  if identity.project.len > 0: result.add " project=" & identity.project
  if identity.runId.len > 0: result.add " run=" & identity.runId
  if identity.runAttempt.len > 0: result.add " attempt=" & identity.runAttempt
  if identity.builtAt.len > 0: result.add " at=" & identity.builtAt
  result.add "\n"

proc parseBuildId*(text: string): BuildIdentity =
  ## The inverse, and the reason the gate cannot pass vacuously.
  ##
  ## Returns the EMPTY identity for anything that is not the one-line form —
  ## most importantly for an HTML document, which is what Cloudflare Pages
  ## serves at this path with a 200 when the file was never published. So
  ## "parsed" is a real claim about the bytes rather than about the request.
  ##
  ## Only the first non-empty line is read: BlockTracer's file is one line, and
  ## a reader that scanned the whole body would happily find a `builtFrom` in a
  ## page that merely mentioned one.
  var first = ""
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    first = line
    break
  if first.len == 0: return BuildIdentity()
  let fields = first.splitWhitespace()
  if fields.len < 2 or fields[0] != "builtFrom": return BuildIdentity()
  if not isCommitName(fields[1]): return BuildIdentity()
  result.commit = fields[1]
  for field in fields[2 .. ^1]:
    let cut = field.find('=')
    if cut <= 0 or cut == field.len - 1: continue
    let key = field[0 ..< cut]
    let value = field[cut + 1 .. ^1]
    case key
    of "branch": result.branch = value
    of "project": result.project = value
    of "run": result.runId = value
    of "attempt": result.runAttempt = value
    of "at": result.builtAt = value
    else: discard

proc buildIdDefects*(body: string; expectedCommit: string): seq[string] =
  ## Everything wrong with a body served at `/build-id.txt`, as sentences.
  ## Empty is the assertion a deploy makes about the host it just published to.
  ##
  ## `expectedCommit` is the revision the run BUILT. Passing "" asks only "is
  ## this a build identity at all", which is what a by-hand probe of an
  ## arbitrary host wants; passing a commit makes it the identity test the
  ## deploy needs, and THAT is the half a status-code check cannot reach.
  ##
  ## A value rather than a shell pipeline for the same reason
  ## `deployGuardDefects` is: the rule is testable on both backends, on inputs
  ## that never touch a network — including the SPA fallback, which is the
  ## input that made every previous version of this check meaningless.
  let identity = parseBuildId(body)
  if identity.commit.len == 0:
    let trimmed = body.strip()
    if trimmed.len == 0:
      result.add "the body is empty, so this host publishes no build identity"
    elif trimmed.len > 0 and trimmed[0] == '<':
      # NAMED, because this is the answer a host gives for a file it does not
      # have, and reading it as "absent" rather than as "broken" is what tells
      # an operator to look at the deploy rather than at the file.
      result.add "the body is an HTML document, not a build identity — " &
        "Cloudflare Pages answers an absent " & buildIdAddress & " with the " &
        "SPA entry document at 200, so this is exactly what a deployment " &
        "that never published the file looks like"
    else:
      result.add "the body is not a build identity: expected a line " &
        "`builtFrom <40-hex-sha> branch=<name>`, got: " &
        (if trimmed.len > 120: trimmed[0 ..< 120] & "…" else: trimmed)
    return
  if identity.branch.len == 0:
    result.add "the build identity names commit " & identity.commit &
      " but no branch, so it cannot say which deployment this is"
  if expectedCommit.len > 0 and identity.commit != expectedCommit:
    result.add "this host serves " & identity.commit & ", but the revision " &
      "under test is " & expectedCommit & " — the deployment is not the one " &
      "that was just built"

proc buildIdentityOf*(descriptor: DeploymentDescriptor): BuildIdentity =
  ## The identity carried by an entry document, so the page and the file are
  ## two renderings of one fact rather than two facts that can disagree.
  BuildIdentity(commit: descriptor.commit, branch: descriptor.branch)

proc buildIdentityLabel*(identity: BuildIdentity): string =
  ## The identity as ONE SHORT STRING for a UI, or "" when there is none.
  ##
  ## "" is load-bearing: a desktop build carries no deployment descriptor, and
  ## a label reading `build unknown` in the Electron app would be a new piece
  ## of furniture that says nothing. The surfaces that show this render nothing
  ## at all for the empty string, so the desktop DOM is byte-for-byte what it
  ## was.
  ##
  ## The commit is ABBREVIATED here and only here. The file publishes the full
  ## name because a machine compares it; a person reading a status bar wants
  ## the eight characters they will type into `git show`, and `title=` carries
  ## the rest (see the callers).
  if identity.commit.len == 0: return ""
  result = identity.commit[0 ..< min(8, identity.commit.len)]
  if identity.branch.len > 0: result = identity.branch & " " & result

proc buildIdentityTitle*(identity: BuildIdentity): string =
  ## The full identity, for a `title=` attribute — the affordance that turns an
  ## eight-character label into something a user can paste into a bug report.
  if identity.commit.len == 0: return ""
  result = "built from " & identity.commit
  if identity.branch.len > 0: result.add " on branch " & identity.branch
  if identity.builtAt.len > 0: result.add " at " & identity.builtAt
