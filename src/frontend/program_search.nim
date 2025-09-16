import std / [async, sequtils, strutils, os, jsre]
import index_config, jsffi, lib, types
import index/ipc_events/traces

let fs = cast[FS](require("fs"))

type MatchResult = ref object

func execs*(self: RegExp; pattern: cstring): MatchResult {.importjs: "(#.exec(#))".}
func `[]`(self: MatchResult, index: int): cstring {.importjs: "(#[#])".}
func index(self: MatchResult): int {.importjs: "(#.index)".}

proc doTextSearch(args: cstring): Future[seq[CommandPanelResult]] {.async.} =
  echo "Text search: ", args

  var filenames = await loadFilenames(@[], data.trace.outputFolder, true)

  var res: seq[CommandPanelResult] = @[]

  # TODO: This is slow. maybe use rg program?
  let re = newRegExp(args, cstring"giu")
  for filename in filenames:
    let filepath = $data.trace.outputFolder / "files" / filename
    if fs.existsSync(filepath) and fs.lstatSync(filepath).isFile():
      let txt = fs.readFileSync(filepath, cstring"utf8")
      var linenum = 0
      for line in txt.split("\n"):
        linenum += 1

        var firstIndex = 0
        re.lastIndex = 0

        var highlighted = ""

        var match = re.execs(line)
        while not isNull(match):
          highlighted &= ($line)[firstIndex .. (match.index - 1)]
          highlighted &= "<b>"
          highlighted &= ($line)[match.index .. (re.lastIndex - 1)]
          highlighted &= "</b>"

          firstIndex = re.lastIndex
          match = re.execs(line)


        if firstIndex != 0:
          highlighted &= ($line)[firstIndex .. ^1]

          res.add(
            CommandPanelResult(
              value: line,
              valueHighlighted: highlighted,
              level: NotificationInfo,
              kind: TextSearchQuery,
              file: filename,
              line: linenum
            )
          )

  return res

proc doProgramSearch*(query: string, debugSend: proc(self: js, f: js, id: cstring, data: js), mainWindow: js) {.async.} =
  let ind = query.find(" ")

  var command = ""
  var args = ""

  if ind == -1:
    command = query
  else:
    command = query[0 .. (ind - 1)]
    args = query[(ind + 1) .. ^1]

  var data: seq[CommandPanelResult] = @[]
  if command.toLower() in ["rg", "grep", "find-in-files"]:
    data = await doTextSearch(cstring args)
  elif command in ["sym"]:
    echo "Symbol search"
    # TODO
  else:
    echo "Unknown command ", command
    # TODO: what to do?

  debugSend(mainWindow.webContents, mainWindow.webContents.send, cstring"CODETRACER::program-search-results", data.toJs)

