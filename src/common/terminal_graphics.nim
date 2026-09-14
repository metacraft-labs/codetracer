## terminal_graphics.nim — PLAT-14's package facade.
##
## `codetracer-specs/Front-Ends/CodeTracer-TUI-Graphics.md` §2: rendering an
## image into cells, so that terminal graphics are a feature of the TUI rather
## than a feature of Kitty.
##
## Seven modules, in dependency order:
##
##   * `tiers` — §2.1's seven tiers as a value, with the ordering every
##     "fail toward the safer answer" rule is written against.
##   * `raster` — the RGBA input and its box filter.
##   * `oklab` — §2.3's perceptual space.
##   * `aspect` — §2.4's correction, visible in the model.
##   * `cell_render` — the per-cell argmin over (glyph, fg, bg).
##   * `magnifier` — PLAT-15 §5's two-stage pixel picking: which source pixels
##     one cell shows, and the magnified overlay in which one source pixel is
##     one or more whole cells so a coordinate can be ADDRESSED rather than
##     inferred.
##   * `media` — which §5.2 media types a resolved terminal can draw, which is
##     PLAT-12's `Budget.media` for a terminal surface.
##   * `emit` — THE BYTES. The only module that produces a string a terminal
##     reads, and therefore the only one a test has to assert against to be
##     asserting an effect.
##
## The DECISION — which tier this terminal, this multiplexer and this link
## allow — is deliberately NOT here: it needs `TerminalEnv`, which is the
## front-end's, and it lives in `src/frontend/tui/app/theme/image_capability.nim`
## beside the capability resolution it extends. This package is the vocabulary
## and the renderer; that module is the policy.

import ./terminal_graphics/tiers
import ./terminal_graphics/raster
import ./terminal_graphics/oklab
import ./terminal_graphics/aspect
import ./terminal_graphics/cell_render
import ./terminal_graphics/magnifier
import ./terminal_graphics/emit
import ./terminal_graphics/media

export tiers, raster, oklab, aspect, cell_render, magnifier, emit, media
