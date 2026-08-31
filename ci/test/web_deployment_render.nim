## Render a web deployment's three generated files, for the assembly step.
##
## `web_runtime_assets_manifest.nim` prints WHAT a bundle must carry. This
## prints the files that carry it: the entry document, the rewrite table and
## the cache table. All three are emitted by `platform/web_deployment.nim`, so
## they are outputs of the product rather than hand-written host configuration
## — the property that module's header claims and, until now, only claimed:
## `renderRewriteConfig` and `renderCacheConfig` existed and NOTHING CALLED
## THEM outside a unit test, and `renderEntryDocument` did not exist at all, so
## every rewrite pointed at an `/index.html` no assembly step produced.
##
## Compiled and run by `ci/test/web-bundle-assets.sh`, for the same reason the
## manifest program is: a helper that no lane compiles is the next
## `host/web_browser.nim`, which sat unparseable on `dev` for days.
##
## Usage:
##   web_deployment_render <origin> <revision> <out-dir> < modules.tsv
##
## stdin is one line per wasm module the assembly step ACTUALLY PLACED, with
## its measured size:
##
##   <id>\t<url>\t<bytes>\t<builtFrom>
##
## Empty stdin is not an error — it is a deployment that ships no toolchain,
## which is a supported configuration with a stated behaviour. It produces a
## document declaring no modules, a page that reports `toolchain=(none)`, and
## a registry that refuses `nargo` by name.

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/web_deployment

when isMainModule:
  if paramCount() < 3:
    stderr.writeLine "usage: web_deployment_render <origin> <revision> <out-dir>"
    quit 2
  let origin = paramStr(1)
  let revision = paramStr(2)
  let outDir = paramStr(3)

  var descriptor = DeploymentDescriptor(origin: origin, revision: revision)
  for rawLine in stdin.lines:
    let line = rawLine.strip()
    if line.len == 0: continue
    let fields = line.split('\t')
    if fields.len < 4:
      stderr.writeLine "malformed module line (want 4 tab-separated fields): " &
        line
      quit 2
    var bytes = 0
    try:
      bytes = parseInt(fields[2])
    except ValueError:
      stderr.writeLine "module `" & fields[0] & "` has a non-numeric size: " &
        fields[2]
      quit 2
    # A module with no provenance is REFUSED here rather than written out and
    # silently dropped by the page. `registrableModules` discards it, so a
    # descriptor containing one would advertise a module the tab then does not
    # register — the deployment and the product disagreeing, quietly, which is
    # the whole failure class this file exists inside.
    if fields[3].strip().len == 0:
      stderr.writeLine "module `" & fields[0] & "` declares no provenance; " &
        "the page would drop it while the deployment served it"
      quit 2
    descriptor.modules.add DeployedModule(
      id: fields[0], url: fields[1], bytes: bytes, builtFrom: fields[3])

  createDir outDir
  writeFile outDir / entryDocumentPath, renderEntryDocument(descriptor)

  let contract = deploymentContract(origin)
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
