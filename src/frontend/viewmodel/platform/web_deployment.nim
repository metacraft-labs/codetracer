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
  for rule in contract.rewrites:
    result.add rule.prefix & "/*  /index.html  200\n"
    result.add rule.prefix & "  /index.html  200\n"

proc renderCacheConfig*(contract: DeploymentContract): string =
  result = "# Generated from viewmodel/platform/web_deployment.nim. Do not edit.\n"
  result.add "# Noir-Studio.md §1b.4 — three cache classes keyed on path prefix.\n"
  result.add "# Most specific first: the first matching rule wins.\n"
  for rule in contract.caches:
    result.add rule.pattern & "\n"
    result.add "  Cache-Control: " & rule.headerValue & "\n"
