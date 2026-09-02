## Render a web deployment's three generated files, for the assembly step.
##
## `web_runtime_assets_manifest.nim` prints WHAT a bundle must carry. This
## prints the files that carry it: the entry document, the rewrite table and
## the cache table. All three are emitted by `platform/web_deployment.nim`, so
## they are outputs of the product rather than hand-written host configuration
## — the property that module's header claims and, until now, only claimed:
## `renderRewriteConfig` and `renderCacheConfig` existed and NOTHING CALLED
## THEM outside a unit test, and `renderEntryDocument` did not exist at all, so
## every rewrite pointed at a target no assembly step produced. (That target
## is `/` now, not `/index.html` — see `web_deployment.entryDocumentAddress`
## for the 308 the second spelling cost.)
##
## Compiled and run by `ci/test/web-bundle-assets.sh`, for the same reason the
## manifest program is: a helper that no lane compiles is the next
## `host/web_browser.nim`, which sat unparseable on `dev` for days.
##
## Usage:
##   web_deployment_render <origin> <revision> <out-dir> [language-origins]
##     < modules.tsv
##
## `language-origins` is a comma-separated list of `<origin>=<language>` pairs
## naming the hosts whose ROOT is a language entry point — e.g.
## `https://noirstudio.dev=noir`. It is an ARGUMENT and not a constant for the
## reason `platform/web_entry.nim`'s header gives: the product's host has moved
## twice already and each move found a constant somebody had to hunt for.
## Adding a second domain is a deploy-time argument, not a code change.
##
## stdin is one line per file the assembly step ACTUALLY PLACED under
## `/assets/`, at the name it was published under and with its measured size.
## The first field says which kind of row it is:
##
##   module\t<id>\t<url>\t<bytes>\t<builtFrom>
##   asset\t<id>\t<url>\t<bytes>
##
## A `module` is `damFetched` — something a run-time consumer resolves by id
## from a `configure` message. An `asset` is `damAsset`: a worker script the
## product loads by URL. They are separate rows rather than one list because
## `declaredModuleUrls` is what a worker's `configure` message carries, and a
## worker script in that list would be handed to itself to instantiate.
##
## The `asset` rows are why this format grew a kind column at all. Before
## content-addressed filenames the worker scripts needed no declaration: their
## URLs were Nim constants, and a constant was a perfectly good answer for a
## file whose name never changed. A name derived from the bytes cannot be a
## constant, so the deployment has to say where it put them.
##
## Empty stdin is not an error — it is a deployment that ships no toolchain,
## which is a supported configuration with a stated behaviour. It produces a
## document declaring no modules, a page that reports `toolchain=(none)`, and
## a registry that refuses `nargo` by name. It is NOT, however, a deployment
## that gets `immutable`: see `staticAssetGlobClass`.

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/web_deployment

when isMainModule:
  if paramCount() < 3:
    stderr.writeLine "usage: web_deployment_render <origin> <revision> <out-dir>"
    quit 2
  let origin = paramStr(1)
  let revision = paramStr(2)
  let outDir = paramStr(3)
  let languageOriginsArg = if paramCount() >= 4: paramStr(4) else: ""

  var descriptor = DeploymentDescriptor(origin: origin, revision: revision)
  for rawPair in languageOriginsArg.split(','):
    let pair = rawPair.strip()
    if pair.len == 0: continue
    let cut = pair.find('=')
    # REFUSED rather than dropped, in the same spirit as a module with no
    # provenance below: a malformed host declaration would silently leave
    # `noirstudio.dev` resolving to the language-neutral root, which looks
    # exactly like a working single-domain deployment and is the failure this
    # whole change exists to stop being invisible.
    if cut <= 0 or cut == pair.len - 1:
      stderr.writeLine "malformed language origin (want <origin>=<language>): " &
        pair
      quit 2
    descriptor.languageOrigins.add OriginLanguage(
      origin: pair[0 ..< cut].strip(), language: pair[cut + 1 .. ^1].strip())
  proc sizeOf(id, raw: string): int =
    try:
      return parseInt(raw)
    except ValueError:
      stderr.writeLine "`" & id & "` has a non-numeric size: " & raw
      quit 2

  for rawLine in stdin.lines:
    let line = rawLine.strip()
    if line.len == 0: continue
    let fields = line.split('\t')
    # AN UNRECOGNISED KIND IS REFUSED, not skipped. A `continue` here would let
    # a typo in the assembly step drop a real published file out of the
    # descriptor, and a file published without a declaration is the exact state
    # `deployGuardDefects` exists to catch — reached, in that case, by the
    # program that writes the declaration.
    case (if fields.len > 0: fields[0] else: "")
    of "module":
      if fields.len < 5:
        stderr.writeLine "malformed module line (want 5 tab-separated " &
          "fields: module, id, url, bytes, builtFrom): " & line
        quit 2
      # A module with no provenance is REFUSED here rather than written out and
      # silently dropped by the page. `registrableModules` discards it, so a
      # descriptor containing one would advertise a module the tab then does not
      # register — the deployment and the product disagreeing, quietly, which is
      # the whole failure class this file exists inside.
      if fields[4].strip().len == 0:
        stderr.writeLine "module `" & fields[1] & "` declares no provenance; " &
          "the page would drop it while the deployment served it"
        quit 2
      descriptor.modules.add DeployedModule(
        id: fields[1], url: fields[2],
        bytes: sizeOf(fields[1], fields[3]), builtFrom: fields[4])
    of "asset":
      if fields.len < 4:
        stderr.writeLine "malformed asset line (want 4 tab-separated fields: " &
          "asset, id, url, bytes): " & line
        quit 2
      descriptor.assets.add PublishedAsset(
        id: fields[1], url: fields[2], bytes: sizeOf(fields[1], fields[3]))
    else:
      stderr.writeLine "unknown row kind `" &
        (if fields.len > 0: fields[0] else: "") &
        "` (want `module` or `asset`): " & line
      quit 2

  # EVERY PUBLISHED `/assets/` URL CARRIES A DIGEST, refused here rather than
  # absorbed by the header table.
  #
  # `staticAssetGlobClass` would simply answer `ccMutableAsset` and emit a
  # correct, revalidating rule for the whole directory — a deployment that
  # works and quietly re-pays ~34 MB of conditional requests per page load
  # because of one file. That is a regression nobody would see. It is a build
  # failure naming the file instead.
  let unhashed = unhashedStaticAssets(descriptor)
  if unhashed.len > 0:
    for path in unhashed:
      stderr.writeLine "published under a stable name, so /assets/* cannot be " &
        "immutable: " & path
    quit 2

  # A DECLARATION THAT CANNOT MATCH IS REFUSED HERE, not discovered in a
  # browser. Its symptom is a working product at the generic entry point and
  # silence — see `unmatchableLanguageOrigins`.
  let unmatchable = unmatchableLanguageOrigins(descriptor)
  if unmatchable.len > 0:
    for problem in unmatchable:
      stderr.writeLine "language origin can never match: " & problem
    quit 2

  createDir outDir
  writeFile outDir / entryDocumentPath, renderEntryDocument(descriptor)

  let contract = deploymentContract(origin, descriptor)
  # Cloudflare Pages reads `_headers` and `_redirects` from the publish root.
  # Both are emitted from the contract, so a cache class or a rewrite prefix
  # added to the product reaches the CDN without anybody editing a second file.
  writeFile outDir / "_headers", renderCacheConfig(contract)
  writeFile outDir / "_redirects", renderRewriteConfig(contract)

  # For the gate and the deploy log: what was declared, so a human reading the
  # run can see the delivery without opening the HTML.
  for module in descriptor.modules:
    echo "declared\t" & module.id & "\t" & module.url & "\t" & $module.bytes &
      "\t" & module.builtFrom
  if descriptor.modules.len == 0:
    echo "declared\t(no wasm modules)"
  for asset in descriptor.assets:
    echo "declared-asset\t" & asset.id & "\t" & asset.url & "\t" & $asset.bytes

  # THE CACHE CLASS THE PUBLISHED SET EARNED, in the deploy log, because it is
  # derived and therefore invisible in any file a human edits. `immutable` here
  # is the whole point of the digests; `max-age=0` here after a change to the
  # assembly step is the sentence that says the digests stopped being emitted.
  echo "assets-cache-class\t" & $staticAssetGlobClass(descriptor) & "\t" &
    headerFor(staticAssetGlobClass(descriptor)) & "\tover " &
    $publishedStaticAssets(descriptor).len & " published /assets/ file(s)"

  # The host map, in the deploy log. A two-domain deployment must be SEEN to be
  # one: `languageOrigins` is the only difference between a bundle that makes
  # `noirstudio.dev` the Noir entry point and one that leaves it generic, and
  # the two are otherwise byte-identical.
  for declared in declaredLanguageOrigins(descriptor):
    echo "language-origin\t" & declared
  if descriptor.languageOrigins.len == 0:
    echo "language-origin\t(none — every host is the language-neutral root)"
