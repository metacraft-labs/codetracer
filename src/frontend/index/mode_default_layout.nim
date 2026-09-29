## index/mode_default_layout.nim — **the one function that turns the bundled
## layout into a mode's default layout.**
##
## `src/config/default_layout.json` is the BUNDLED tree: nobody's layout, the
## input every mode's default is derived from (it still gives TEST RESULTS and
## CONSTRAINTS a column of their own, because the editing surface keeps
## CONSTRAINTS there). A mode's default is that tree with the panes the mode
## does not show or does not start with removed
## (`frontend.modeDefaultHiddenContentIds`) and the panes the mode homes
## elsewhere moved (`frontend.paneHomesForMode`) — `modeDefaultLayoutConfig`
## in `layout_config_repair`, with the mode's two tables.
##
## ## Three callers, one function
##
## * the renderer (`ui/mode_layouts.bundledLayoutForMode`) — a mode switch
##   with no saved layout for the entered mode, and the renderer's fallback
##   when a saved layout cannot be restored;
## * the index process (`index/config.loadLayoutConfig` /
##   `resetLayoutToDefault`) — the desktop's FIRST RUN and View > Reset
##   Layout, which used to install the raw bundled tree and so showed a
##   standing TEST RESULTS / CONSTRAINTS column no mode draws;
## * the default-layout generator
##   (`headless_app/generate_default_layout.nim`, compiled with `nim js` and
##   run under node for exactly this reason) — which reads the DEBUG-mode
##   default this function produces back into the shared vocabulary and
##   writes it as the arrangement the terminal and the GPUI window open with
##   (`headless_app/layout_model.sharedDefaultLayout`).
##
## So the desktop's debug-mode default and every other front-end's first
## screen are one computation, not two computations that are asserted equal.
## Before this module the generator translated the RAW bundled tree, and the
## terminal therefore drew the column the desktop's own code calls "nobody's
## layout" (the 2026-09-27 report, and
## `issues/2026-09-27-desktop-mode-default-differs-from-shared-default.md`).
##
## JavaScript only: `layout_config_repair` is `importjs` over the GoldenLayout
## config the desktop loads, so this runs in the renderer, the index process
## and node — never in a C build.

import std/jsffi

import ./layout_config_repair

export layout_config_repair

template modeDefaultLayout*(bundled: js; mode: untyped): js =
  ## `mode`'s default layout, derived from the bundled GoldenLayout config
  ## `bundled` (which is not modified).
  ##
  ## A TEMPLATE, and deliberately so: the per-mode tables and the `Content`
  ## ordinals (`frontend.modeDefaultHiddenContentIds`, `.paneHomesForMode`)
  ## are resolved where it is used. The desktop compiles `common_types` into
  ## `frontend/types` (with `cstring` strings) and the generator into
  ## `common/types` (with `string`s), so the two `LayoutMode` types are
  ## distinct types spelled from ONE source file; importing either here would
  ## make the other caller's mode argument the wrong type. The derivation —
  ## this body — and the tables are still written exactly once.
  modeDefaultLayoutConfig(bundled, ord(Content.EditorView),
                          modeDefaultHiddenContentIds(mode),
                          paneHomesForMode(mode))
