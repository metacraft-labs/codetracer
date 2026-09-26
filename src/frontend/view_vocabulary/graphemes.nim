## frontend/view_vocabulary/graphemes.nim — the UAX #29 cluster segmenter
## every front-end binding hands the vocabulary.
##
## `vocabulary.ClusterBoundaries` explains why an `Input`'s caret counts
## extended grapheme clusters and why the vocabulary cannot segment on its
## own (the property tables are isonim-tui's, and `src/common` must not import
## isonim-tui). The bindings can, and this is the one place they do it, so the
## terminal, the web and GPUI cannot end up on three segmenters.
##
## `isonim_tui/text/width` is the same module the ViewModel's editor core
## segments with (`viewmodel/editor/selection_ops.clusterBoundariesOf`): pure
## Nim over generated Unicode 16 tables, no renderer, no terminal, and it
## compiles for C, JavaScript and WebAssembly. Importing it links no terminal
## front-end into the web or GPUI binding.

import isonim_tui/text/width as widthMod

func graphemeBoundaries*(s: string): seq[int] {.nimcall.} =
  ## Every extended-grapheme-cluster boundary of `s` as a byte offset,
  ## ascending, including 0 and `s.len` — `vocabulary.ClusterBoundaries`'s
  ## contract, answered by UAX #29
  ## (https://unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries).
  result = @[0]
  for c in graphemeClusters(s):
    if c.stop > result[^1]: result.add c.stop
  if result[^1] != s.len: result.add s.len
