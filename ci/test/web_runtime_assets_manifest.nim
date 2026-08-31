## Print the web deployment's runtime-asset manifest, for the shell gate.
##
## `ci/test/web-bundle-assets.sh` has to know which files a bundle must carry.
## The wrong way to give it that is a list in the script, because a list in a
## script cannot be made to agree with the product — which is the argument
## `platform/web_deployment.nim`'s own header makes about `rewritePrefixes`,
## and the defect it records: someone adds an asset, the application uses it,
## and the assembly step never places it because nobody edited the second copy.
##
## So the manifest is a value in `web_deployment.nim`, compiled and asserted on
## both backends by `viewmodel/tests/unit/test_platform_web.nim`, and this
## program is the only bridge to the shell. It prints TSV and nothing else.
##
## Compiled by `ci/test/web-bundle-assets.sh` itself, which is what keeps this
## file from becoming the next thing no lane compiles — the failure mode that
## cost this repository `host/web_browser.nim` and, this week, the renderer
## entry point. `ci/test/desktop_capabilities_dispatch_check.nim` is the same
## pattern.

import std/strutils

import ../../src/frontend/viewmodel/platform/web_deployment

proc modeName(mode: DeliveryMode): string =
  case mode
  of damBundled: "bundled"
  of damAsset: "asset"
  of damFetched: "fetched"
  of damEntryDocument: "entry-document"

when isMainModule:
  # One line per asset: id, path, mode, required, absence behaviour.
  # Tab-separated because a path never contains a tab and an absence sentence
  # frequently contains a comma.
  for asset in webRuntimeAssets():
    echo [asset.id,
          asset.path,
          modeName(asset.mode),
          (if asset.required: "required" else: "optional"),
          asset.absenceBehaviour].join("\t")
