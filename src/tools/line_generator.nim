# generates lines for tests
import strutils, sequtils, tables, future, streams, db_sqlite


var db = db_sqlite.open("/home/alehander42/db/t.db", "", "", "")

type
  Metadata = ref object
    functions: Table[string, int]
    functionNames: Table[int, string]
    functionModules: Table[int, string]
    mangled: Table[int, string]

proc parseMetadata(path: string): Metadata =
  var data = readFile(path)
  var lines = data.splitLines()
  var count = parseInt(lines[0])
  result = Metadata()
  result.functionNames = initTable[int, string]()
  result.functions = initTable[string, int]()
  result.functionModules = initTable[int, string]()
  result.mangled = initTable[int, string]()
  lines = lines[1.. ^1]
  for n in lines:
    var tokens = n.split(" ")
    if len(tokens) < 4:
      break
    var id = parseInt(tokens[0])
    result.functionNames[id] = tokens[1][1..^2]
    result.functions[tokens[1][1..^2]] = id
    result.functionModules[id] = tokens[2]
    result.mangled[id] = tokens[3]

proc visitedLines(count: uint = 20_000) =
  var metadata = parseMetadata("/home/alehander42/db/metadata.txt")
  var lines: seq[string] = @[]
  for line in db.fastRows(sql("SELECT line, functionID FROM `lines` WHERE codeID IN (SELECT codeID FROM `lines` ORDER BY RANDOM() LIMIT $1)" % $count)):
    lines.add(metadata.functionModules[parseInt(line[1])] & " " & line[0] & "\n")
  writeFile("lines.txt", lines.join())

visitedLines(20_000)

