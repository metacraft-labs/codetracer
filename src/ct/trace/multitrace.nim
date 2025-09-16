import std / [os, osproc, strformat, sequtils, strutils]
import json_serialization
import .. / .. / common / trace_index
import .. / .. / common / types
import .. / utilities / zip

proc findDiff(diffSpecification: string): string =
  if diffSpecification.len > 0:
    if diffSpecification == "last-commit":
      execProcess(findExe("git"), args = @["diff", "HEAD~..HEAD"], options = {poEchoCmd})
    else:
      var path = diffSpecification
      try:
        # try to support arguments like `~/<path>`
        path = expandFileName(diffSpecification)
      except OsError:
        discard

      if existsFile(path):
        # assume it contains a diff
        # AND that we're in the actual repo as well
        readFile(path)
      else:
        # for now assume git range syntax
        execProcess(findExe("git"), args = @["diff", diffSpecification], options = {poEchoCmd})
  else:
    ""

proc parseDiff(rawDiff: string): Diff =
    result = Diff()
    if rawDiff.len > 0:
      let lines = rawDiff.splitLines()
      var fileDiff: FileDiff = nil
      var chunk = Chunk()
      var chunkPreviousFileLineNumber = 0
      var chunkCurrentFileLineNumber = 0

      for line in lines:
        # echo "line ", line
        if line.startsWith("--- a/"):
          let path = line["--- a/".len .. ^1]
          fileDiff.previousPath = expandFileName(path)
        elif line.startsWith("+++ b/"):
          let path = line["+++ b/".len .. ^1]
          fileDiff.currentPath = expandFileName(path)
        elif line.startsWith("diff "):
          if not fileDiff.isNil:
            if chunk.previousFrom != 0:
              fileDiff.chunks.add(chunk)
              chunk = Chunk()
          fileDiff = FileDiff()
          result.files.add(fileDiff)
        elif line.startsWith("@@ -"):
          if chunk.previousFrom != 0:
            if not fileDiff.isNil:
              fileDiff.chunks.add(chunk)
          let tokens = line.splitWhitespace()
          chunk = Chunk()
          # @@ -previousFrom,previousCount +currentFrom,currentCount @@
          let previousToken = tokens[1][1..^1].split(",")
          chunk.previousFrom = previousToken[0].parseInt
          chunkPreviousFileLineNumber = chunk.previousFrom
          chunk.previousCount = previousToken[1].parseInt
          let currentToken = tokens[2][1..^1].split(",")
          chunk.currentFrom = currentToken[0].parseInt
          chunkCurrentFileLineNumber = chunk.currentFrom
          chunk.currentCount = currentToken[1].parseInt
        else:
          if line.len < 1:
            # ignore: assume it's always <kind><text>
            discard
          else:
            let firstCharacter = line[0]
            let (isLineDiff, kind) = case firstCharacter:
              of '+': (true, Added)
              of '-': (true, Deleted)
              of ' ': (true, NonChanged)
              # not expected to have another symbol: probably a diff metadata line, line `diff `, `index`
              # or `new mode ` or other:
              else:   (false, NonChanged) 
            if isLineDiff:
              var diffLine = DiffLine(
                kind: kind,
                text: line[1..^1])
              if kind in {Deleted, NonChanged}:
                diffLine.previousLineNumber = chunkPreviousFileLineNumber
                if kind == Deleted:
                  diffLine.currentLineNumber = NO_LINE
                chunkPreviousFileLineNumber += 1
              if kind in {Added, NonChanged}:
                if kind == Added:
                  diffLine.previousLineNumber = NO_LINE
                diffLine.currentLineNumber = chunkCurrentFileLineNumber
                chunkCurrentFileLineNumber += 1
              chunk.lines.add(diffLine)

      if not fileDiff.isNil:
        if chunk.previousFrom != 0:
          fileDiff.chunks.add(chunk)

proc makeMultitraceArchive(traceFolders: seq[string], rawDiff: string, structuredDiff: Diff, outputPath: string) =
  let folder = getTempDir() / "codetracer" / "multitrace-" & outputPath.extractFilename # TODO a more unique name?
  removeDir(folder)
  createDir(folder)

  for traceFolder in traceFolders:
    copyDir(traceFolder, folder / traceFolder.extractFilename)

  writeFile(folder / "original_diff.patch", rawDiff)
  writeFile(folder / "diff.json", Json.encode(structuredDiff, pretty=true))
  # for now no diff_data.json or other format: eventually from diff-index

  zipFolder(folder, outputPath)

  removeDir(folder)

proc makeMultitrace*(traceIdList: seq[int], diffSpecification: string, outputPath: string) =
  # make a folder , copy those traces , find this diff, eventually parse it and store it
  # TODO: eventually diff-index in the future
  # in the future store as a new trace-id?
  # for now in a custom place
  
  # find the diff, parse
  let rawDiff = findDiff(diffSpecification)
  # echo rawDiff
  let structuredDiff = parseDiff(rawDiff)
  let traceFolders = traceIdList.mapIt(trace_index.find(it, test=false).outputFolder)
  makeMultitraceArchive(traceFolders, rawDiff, structuredDiff, outputPath)
  echo fmt"OK: created multitrace in {outputPath}"

