import json_serialization, json_serialization/std/tables, times, strutils
import std/[json, tables]

const
  # The macro_sourcemap_*.json schema version this parser supports.
  # Bumped to 2 in §2-M1 (compiler SHA 82da134b8). The shipping schema:
  # - top-level `"schema": 2`
  # - `expansions[].site` / `.definition` are objects `{file, line, col}`
  # - `locations` entries carry `siteFile`/`siteLine`/`siteCol`/`expansionId`/
  #   `entryExpandedLine`/`entryExpandedCol`
  # - new `expressionLocations` map keyed by `"<line>:<col>"`
  # See codetracer-specs/Nim-Compiler-Patches.md §2-M1 for the full spec.
  MacroSourcemapSupportedSchema* = 2

type
  RawSourcemap* = object
    cSources*:        Table[string, int]
    nimSources*:      Table[string, int]
    mappings*:        seq[Table[string, seq[seq[PathIDLine]]]]

  Sourcemap* = object
    cSources*:        Table[int, string]
    nimSources*:      Table[int, string]
    cIDs*:            Table[string, int]
    nimIDs*:          Table[string, int]
    c*:               Table[string, Table[int, seq[seq[PathIDLine]]]]
    nim*:             Table[string, Table[int, PathIDLine]]

  PathIDLine* = array[2, int]

  # The following types model the schema-2 `macro_sourcemap_*.json` shape
  # emitted by the Nim compiler under `--sourcemap:on`. They mirror the
  # compiler-side `options.nim` `MacroSourcemap` structure adapted to the
  # CodeTracer frontend.
  #
  # Field changes versus the pre-M1 shape (kept here as a single source of
  # truth so consumers don't have to consult the spec):
  #   * `Expansion.site`/`Expansion.definition` carry a column in addition
  #     to file and line.
  #   * `ExpansionInfo.siteInfo` carries a column.
  #   * `ExpansionInfo` adds `entryExpandedCol` alongside `entryExpandedLine`.
  #   * `MacroSourcemap` gains `expressionLocations` keyed by `(line, col)`.
  #     The legacy line-only `locations` table is preserved so existing
  #     statement-granularity callers keep working.

  MacroSourcemap* = object
    ## Parsed macro sourcemap, one per Nim compilation unit.
    schema*: int
    expansions*: seq[Expansion]
    locations*: OrderedTable[int, ExpansionInfo]
      ## Statement-granularity map: expanded-file line -> expansion info.
    expressionLocations*: OrderedTable[(int, int), ExpansionInfo]
      ## Expression-granularity map: `(expanded-file line, col)` ->
      ## expansion info. Added in schema 2.
    expandedFilename*: string
    expandedEntries*: Table[string, Table[int, int]]
    topLevelLines*: Table[int, (string, int)]

  Expansion* = object
    path*: string
    firstLine*: int
    lastLine*: int
    site*: (string, int, int)
      ## (file, line, col) — column added in schema 2.
    definition*: (string, int, int)
      ## (file, line, col) — column added in schema 2.
    name*: string # empty if not definition
    fromMacro*: bool

  ExpansionInfo* = object
    siteInfo*: (string, int, int)
      ## (file, line, col) — column added in schema 2.
    expansionId*: int
    entryExpandedLine*: int
    entryExpandedCol*: int
      ## Column counterpart to `entryExpandedLine`. Added in schema 2.
      ## A negative value means "no expression entry point recorded".

  MacroSourcemapError* = object of CatchableError
    ## Raised when a `macro_sourcemap_*.json` file is malformed or carries
    ## a schema version this parser does not understand.

proc loadSourcemap*(path: string): (bool, SourceMap) =
  try:
    let rawText = readFile(path)
    # TODO: fix
    GC_disable()
    let raw = Json.decode(rawText, RawSourcemap)
    GC_enable()
    var res = Sourcemap(cIDs: raw.cSources, nimIDs: raw.nimSources)
    if raw.nimSources.len == 0:
      # TODO option
      return (false, res)
    for cSource, cID in raw.cSources:
      res.nim[cSource] = initTable[int, PathIDLine]()
      res.cSources[cID] = cSource
    for nimSource, nimID in raw.nimSources:
      res.c[nimSource] = initTable[int, seq[seq[PathIDLine]]]()
      res.nimSources[nimID] = nimSource
    for nimPathID, mapping in raw.mappings:
      for line, groups in mapping:
        if res.nimSources.hasKey(nimPathID) and res.c.hasKey(res.nimSources[nimPathID]):
          res.c[res.nimSources[nimPathID]][line.parseInt] = groups
          for group in groups:
            for pathIDLine in group:
              res.nim[res.cSources[pathIDLine[0]]][pathIDLine[1]] = [nimPathID, line.parseInt]
    # echo res
    return (true, res)
  except CatchableError as e:
    echo e.msg
    return (false, SourceMap())

proc getIntField(node: JsonNode, key: string, default: int = 0): int =
  ## Defensive accessor: tolerates missing/non-integer fields by returning
  ## `default`. Used while parsing schema-2 macro sourcemaps because the
  ## compiler may legitimately omit absent column data (e.g. statements
  ## with no expression entry produce `entryExpandedLine: -1` /
  ## `entryExpandedCol: -1`).
  if node.isNil:
    return default
  if node.hasKey(key):
    let v = node[key]
    if v.kind == JInt:
      return v.getInt()
  default

proc getStringField(node: JsonNode, key: string, default: string = ""): string =
  if node.isNil:
    return default
  if node.hasKey(key):
    let v = node[key]
    if v.kind == JString:
      return v.getStr()
  default

proc parsePositionInLayer(node: JsonNode): (string, int, int) =
  ## Parses the schema-2 `{file, line, col}` object used for `site` /
  ## `definition` in `expansions[]`.
  if node.isNil or node.kind != JObject:
    return ("", 0, 0)
  let file = getStringField(node, "file")
  let line = getIntField(node, "line")
  let col = getIntField(node, "col")
  (file, line, col)

proc parseExpansionInfo(node: JsonNode): ExpansionInfo =
  ## Parses one schema-2 `locations` / `expressionLocations` entry. The
  ## absent `entryExpandedCol` is left as -1 so consumers can detect
  ## "no expression entry point recorded".
  if node.isNil or node.kind != JObject:
    return ExpansionInfo(entryExpandedLine: -1, entryExpandedCol: -1, expansionId: -1)
  let siteFile = getStringField(node, "siteFile")
  let siteLine = getIntField(node, "siteLine")
  let siteCol = getIntField(node, "siteCol")
  ExpansionInfo(
    siteInfo: (siteFile, siteLine, siteCol),
    expansionId: getIntField(node, "expansionId", -1),
    entryExpandedLine: getIntField(node, "entryExpandedLine", -1),
    entryExpandedCol: getIntField(node, "entryExpandedCol", -1),
  )

proc getBoolField(node: JsonNode, key: string, default: bool = false): bool =
  if node.isNil:
    return default
  if node.hasKey(key):
    let v = node[key]
    if v.kind == JBool:
      return v.getBool()
  default

proc parseExpansion(node: JsonNode): Expansion =
  if node.isNil or node.kind != JObject:
    return Expansion()
  Expansion(
    path: getStringField(node, "path"),
    firstLine: getIntField(node, "firstLine"),
    lastLine: getIntField(node, "lastLine"),
    site: parsePositionInLayer(node{"site"}),
    definition: parsePositionInLayer(node{"definition"}),
    name: getStringField(node, "name"),
    fromMacro: getBoolField(node, "fromMacro"),
  )

proc parseExpressionKey(key: string): (int, int) =
  ## Splits a `"<line>:<col>"` key from `expressionLocations`. Returns
  ## `(line, col)`; raises `ValueError` (caught by the caller) if the key
  ## is malformed.
  let idx = key.find(':')
  if idx < 0:
    return (parseInt(key), 0)
  (parseInt(key[0 ..< idx]), parseInt(key[idx + 1 .. ^1]))

proc loadMacroSourcemap*(path: string): (bool, MacroSourcemap) =
  ## Loads and validates a schema-2 `macro_sourcemap_*.json` file produced
  ## by the patched Nim compiler with `--sourcemap:on`. Returns
  ## `(false, MacroSourcemap())` on any parse / validation failure; the
  ## message is logged to stderr for diagnostic purposes.
  ##
  ## Validation:
  ##  * top-level `schema` field must be present and equal to
  ##    `MacroSourcemapSupportedSchema` (currently 2). The function refuses
  ##    to load older shapes so downstream consumers can rely on the
  ##    schema-2 contract.
  try:
    let raw = parseJson(readFile(path))
    if raw.kind != JObject:
      raise newException(MacroSourcemapError,
        "macro sourcemap: top-level JSON is not an object (" & path & ")")

    let schema = getIntField(raw, "schema", 0)
    if schema != MacroSourcemapSupportedSchema:
      raise newException(MacroSourcemapError,
        "macro sourcemap: unsupported schema " & $schema &
        " (expected " & $MacroSourcemapSupportedSchema & ") in " & path)

    var res = MacroSourcemap(schema: schema)

    let expansionsNode = raw{"expansions"}
    if not expansionsNode.isNil and expansionsNode.kind == JArray:
      for item in expansionsNode:
        res.expansions.add(parseExpansion(item))

    let locationsNode = raw{"locations"}
    if not locationsNode.isNil and locationsNode.kind == JObject:
      for key, value in locationsNode.pairs:
        try:
          let line = parseInt(key)
          res.locations[line] = parseExpansionInfo(value)
        except ValueError:
          # Skip malformed line keys without failing the whole load — the
          # compiler should never produce non-integer keys here, but a
          # corrupt file shouldn't sink the rest of the data.
          continue

    let exprLocationsNode = raw{"expressionLocations"}
    if not exprLocationsNode.isNil and exprLocationsNode.kind == JObject:
      for key, value in exprLocationsNode.pairs:
        try:
          let lineCol = parseExpressionKey(key)
          res.expressionLocations[lineCol] = parseExpansionInfo(value)
        except ValueError:
          continue

    res.expandedFilename = getStringField(raw, "expandedFilename")

    let expandedEntriesNode = raw{"expandedEntries"}
    if not expandedEntriesNode.isNil and expandedEntriesNode.kind == JObject:
      for srcPath, inner in expandedEntriesNode.pairs:
        var innerTbl = initTable[int, int]()
        if inner.kind == JObject:
          for lineStr, expandedLine in inner.pairs:
            try:
              if expandedLine.kind == JInt:
                innerTbl[parseInt(lineStr)] = expandedLine.getInt()
            except ValueError:
              continue
        res.expandedEntries[srcPath] = innerTbl

    let topLevelLinesNode = raw{"topLevelLines"}
    if not topLevelLinesNode.isNil and topLevelLinesNode.kind == JObject:
      for key, value in topLevelLinesNode.pairs:
        try:
          let line = parseInt(key)
          if value.kind == JArray and value.len >= 2:
            let pathNode = value[0]
            let lineNode = value[1]
            if pathNode.kind == JString and lineNode.kind == JInt:
              res.topLevelLines[line] = (pathNode.getStr(), lineNode.getInt())
        except ValueError:
          continue

    return (true, res)
  except CatchableError as e:
    echo e.msg
    return (false, MacroSourcemap())
