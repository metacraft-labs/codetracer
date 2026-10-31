## Browser-safe Source Map V3 loading. Files are read through the caller's
## platform facade; discovery belongs to the main process, including ct host.
import std/[asyncjs, jsffi, strutils, json, tables, jsconsole]
from lib/jslib import hasKey
import nim_sourcemap_types
export nim_sourcemap_types

type
  ReadSourcemapText* = proc(path: cstring): Future[cstring]
  V3Mapping = ref object of JsRoot
    generatedLine, generatedColumn: int
    source: cstring
    originalLine: int
  V3Consumer = ref object of JsRoot

proc consumer(text: cstring): V3Consumer
  {.importjs: "(new (require('source-map-js').SourceMapConsumer)(#))".}
proc eachMapping(map: V3Consumer; visit: proc(mapping: V3Mapping))
  {.importjs: "#.eachMapping(#)".}

proc emptySourcemap(): FrontendSourcemap =
  FrontendSourcemap(
    nimToC: JsAssoc[cstring, JsAssoc[int, seq[seq[SourcemapPathIDLine]]]]{},
    cToNim: JsAssoc[cstring, JsAssoc[int, SourcemapPathIDLine]]{},
    cSources: JsAssoc[int, cstring]{},
    nimSources: JsAssoc[int, cstring]{},
    loaded: false)

proc loadFrontendSourcemap*(paths: seq[cstring]; reader: ReadSourcemapText): Future[FrontendSourcemap] {.async.} =
  ## Merge every module with global path IDs. A broken sidecar is isolated from
  ## the others, and an empty/unreadable set never claims to have loaded.
  ## Source Map V3 decoding and sourceRoot resolution use source-map-js, shared
  ## with the JS toolchain, rather than a second handwritten VLQ decoder.
  var sm = emptySourcemap()
  var nimIDs = initTable[string, int]()
  var nextCID = 0
  for path in paths:
    if path.isNil or not ($path).endsWith(".c.map"):
      continue
    try:
      let text = await reader(path)
      let raw = parseJson($text)
      if raw.kind != JObject or not raw.hasKey("version") or
          raw["version"].getInt() != 3 or not raw.hasKey("sources") or
          raw["sources"].kind != JArray or not raw.hasKey("mappings") or
          raw["mappings"].kind != JString:
        raise newException(ValueError, "expected a Source Map V3 document")
      # Fully decode before mutating the shared lookup, so malformed VLQ cannot
      # leave partial mappings behind when another valid module is loaded.
      let map = consumer(text)
      var mappings: seq[V3Mapping] = @[]
      map.eachMapping(proc(mapping: V3Mapping) = mappings.add(mapping))
      # The sidecar's adjacent C file is authoritative. `file` can still name
      # the original compiler cache after a trace has been moved or copied.
      let cPath = ($path)[0 ..< ($path).len - 4]
      var generated: seq[string] = @[]
      try:
        generated = ($await reader(cstring(cPath))).splitLines()
      except:
        # Match native replay's fallback when the generated text is absent:
        # project at column zero, using the map's generated line count.
        discard
      var byLine = initTable[int, seq[V3Mapping]]()
      var lineCount = generated.len
      for mapping in mappings:
        if mapping.generatedLine < 1 or mapping.generatedColumn < 0:
          raise newException(ValueError, "invalid generated source-map position")
        byLine.mgetOrPut(mapping.generatedLine, @[]).add(mapping)
        lineCount = max(lineCount, mapping.generatedLine)
      var projected: seq[(int, cstring, int)] = @[]
      var inEffect: V3Mapping = nil
      for line in 1 .. lineCount:
        let text = if line <= generated.len: generated[line - 1] else: ""
        let column = text.len - text.strip(leading = true, trailing = false).len
        var atStart = inEffect
        for mapping in byLine.getOrDefault(line):
          if mapping.generatedColumn <= column:
            atStart = mapping
          inEffect = mapping
        # Like native replay, a segment remains in effect across generated
        # lines. Blank lines carry that state but do not become navigation
        # targets. A one-field (unmapped) segment terminates the mapping.
        if line <= generated.len and text.strip().len == 0:
          continue
        if atStart.isNil or atStart.source.isNil or atStart.originalLine < 1:
          continue
        projected.add((line, atStart.source, atStart.originalLine))
      if projected.len == 0:
        continue
      let cID = nextCID
      inc nextCID
      sm.cSources[cID] = cstring(cPath)
      sm.cToNim[cstring(cPath)] = JsAssoc[int, SourcemapPathIDLine]{}
      for (cLine, source, nimLine) in projected:
        let sourcePath = $source
        if not nimIDs.hasKey(sourcePath):
          let id = nimIDs.len
          nimIDs[sourcePath] = id
          sm.nimSources[id] = source
          sm.nimToC[source] = JsAssoc[int, seq[seq[SourcemapPathIDLine]]]{}
        let nimID = nimIDs[sourcePath]
        sm.cToNim[cstring(cPath)][cLine] = [nimID, nimLine]
        # The UI chooses from groups of generated lines. V3's line projection
        # yields one group per C line, as native replay's reader does.
        if not sm.nimToC[source].hasKey(nimLine):
          sm.nimToC[source][nimLine] = @[]
        var groups = sm.nimToC[source][nimLine]
        groups.add(@[[cID, cLine]])
        sm.nimToC[source][nimLine] = groups
      sm.loaded = true
    except:
      console.log cstring"sourcemap: failed to load ", path, cstring(getCurrentExceptionMsg())
  return sm
