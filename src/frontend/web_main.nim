## The HEADLESS entry point for the web instantiation's boot sequence.
##
## ## What this is now, and what it stopped being
##
## It used to be the web deployment's loop arm: `ci/test/web-bundle-assets.sh`
## built it into `web.js`, the generated entry document loaded it beside
## `ui.js`, and it was the only thing in the tree that called `boot()`.
##
## That arrangement is what NS9 removed, and the reason is in `web_boot.nim`'s
## header. `boot()` installs the platform by writing a module-level `var` in
## `viewmodel/platform/platform.nim`; a `nim js` program gets one of those; and
## the deployment ran two programs, each wrapped in its own IIFE by the assets
## script precisely so they would stop redefining each other's runtime. So the
## renderer's `ctPlatform()` could never be the platform this file booted — it
## returned `uninstalledProfile` on every load of the deployed page, which is
## why a Build button had nothing to call. Measured on the pair this replaced:
## `web.js` carried `installPlatform__viewmodelZplatformZplatform_u99` and
## `ui.js` carried no `installPlatform` at all.
##
## The boot call now lives in `ui_js.nim`'s web arm, in the same program as the
## renderer, and the page loads one Nim bundle. That bundle is 380,418 bytes
## SMALLER than the two it replaces, because the shared runtime — the 196
## functions and 85 type tables the IIFEs existed to keep apart — is emitted
## once instead of twice.
##
## ## Why the file survives the arm that used it
##
## Because `ci/test/web-bundle-smoke.sh` is a genuinely different check from
## the browser gate, and it needs an entry point that is *only* the boot
## sequence. It builds this with `nim js -d:nodejs -d:ctWeb` and runs it under
## node, which drives §4.2's third row — no OPFS, the in-memory volume, a
## session that announces it will lose work on close — without a browser, and
## asserts the bundle links no node built-in. Pointing that gate at `ui_js.nim`
## instead would make it a renderer test that happens to boot, and it would
## stop being runnable under node at all.
##
## So: this compiles, and nothing deploys it. `webRuntimeAssets()` no longer
## names a `web.js`, `renderEntryDocument` no longer references one, and
## `ci/test/web-bundle-assets.sh` no longer builds one into the publish
## directory.

import std/[asyncjs]

import web_boot

# Re-exported because `web-bundle-smoke.sh` greps the running program's output
# for `bootLinePrefix`, and because a reader arriving at this file from that
# script should find the two names it talks about here rather than one
# indirection away.
#
# `#` and not `##`, and that is not a style preference: a `##` block after a
# statement is `Error: invalid indentation`. It is the same trap
# `platform_host.nim`'s `ctWeb` arm documents after its `discard`, and the one
# that reached `dev` at ed9d6021 in `web_browser.nim`. It was hit here too,
# writing this file, and caught in seconds because a gate compiles it.
export bootLinePrefix, startWebSession

when isMainModule:
  discard startWebSession()
