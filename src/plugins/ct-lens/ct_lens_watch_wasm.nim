## ct_lens_watch_wasm.nim — `ct-lens.watch` built for CodeTracer's WebAssembly
## plugin host (Extensibility-Model.md §11.9): the same `lens_watch.setupWatch`
## the native `ct-lens-plugins` runs, compiled to one `plugin.wasm` for every
## platform.
##
##   src/plugin_sdk/build-wasm-plugin.sh src/plugins/ct-lens/ct_lens_watch_wasm.nim \
##     <component>/plugin.wasm
##
## Its manifest is `wasm/plugin.json`: package `ct-lens`, `host.kind` `wasm`.
## Unlike the native package it declares `trace` and nothing else, not
## `process`: it reads the mirrored session and relays actions, and its
## instance can reach nothing more.

import codetracer_plugin_sdk
import lens_watch

let sdk = newPluginSdk("ct-lens")
setupWatch(sdk)
sdk.run()
