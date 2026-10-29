## Browser-safe line mapping shared by the renderer and its sourcemap reader.
import std/jsffi

type
  # Nim-to-C sourcemap for ViewTargetSource line synchronization.
  # PathIDLine is [pathID, line] — an index into the cSources/nimSources tables.
  SourcemapPathIDLine* = array[2, int]

  # Frontend-friendly sourcemap representation.
  # Loaded from per-module Source Map V3 .c.map files in the trace nimcache directory.
  FrontendSourcemap* = ref object
    # Maps: nim file path -> nim line -> seq of C line groups
    # Each group is a seq of [cSourceID, cLine] pairs
    nimToC*:   JsAssoc[cstring, JsAssoc[int, seq[seq[SourcemapPathIDLine]]]]
    # Maps: c file path -> c line -> [nimSourceID, nimLine]
    cToNim*:   JsAssoc[cstring, JsAssoc[int, SourcemapPathIDLine]]
    # ID -> path lookups
    cSources*:   JsAssoc[int, cstring]
    nimSources*: JsAssoc[int, cstring]
    loaded*: bool
