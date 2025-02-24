import json_serialization, json_serialization/std/tables, times, strutils

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

  # those next types are copied/adapted from and should be kept in sync with our patch of the compiler: `options.nim`
  #  (macro sourcemap uses only some fields in the serialized form as in `cgen.nim`)

  MacroSourcemap* = object
    expansions*: seq[Expansion]
    locations*: OrderedTable[int, ExpansionInfo]
    expandedFilename*: string
    expandedEntries*: Table[string, Table[int, int]]
    topLevelLines*: Table[int, (string, int)]

  Expansion* = object
    path*: string
    firstLine*: int
    lastLine*: int
    site*: (string, int) #TLineInfo
    definition*: (string, int) #TLineInfo
    # topLevel*: (string, int)
    name*: string # empty if not definition
    fromMacro*: bool

  ExpansionInfo* = object
    siteInfo*: (string, int)
    expansionId*: int
    entryExpandedLine*: int

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

proc loadMacroSourcemap*(path: string): (bool, MacroSourcemap) =
  try:
    let res = Json.decode(readFile(path), MacroSourcemap)
    (true, res)
  except CatchableError as e:
    echo e.msg
    (false, MacroSourcemap())
