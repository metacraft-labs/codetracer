import std / [os, osproc, strformat, sequtils, strutils]
import json_serialization
import .. / .. / common / trace_index
import .. / utilities / zip

proc findDiff(diffSpecification: string): string =
  if diffSpecification.len > 0:
    if diffSpecification == "last-commit":
      execProcess(findExe("git"), args = @["diff", "HEAD~..HEAD"], options = {poEchoCmd})
    else:
      # for now assume git range syntax
      execProcess(findExe("git"), args = @["diff", diffSpecification], options = {poEchoCmd})
  else:
    ""

type
  Diff* = ref object
    files*: seq[FileDiff]

  FileDiff* = ref object
    chunks*: seq[Chunk]
    previousPath*: string
    currentPath*: string
  
  Chunk* = object
    deleteFrom*: int
    deleteCount*: int
    addFrom*: int
    addCount*: int
    lines*: seq[DiffLine]

  DiffLineKind* = enum NonChanged, Deleted, Added

  DiffLine* = object
    kind*: DiffLineKind
    text*: string

proc parseDiff(rawDiff: string): Diff =
    result = Diff()
    if rawDiff.len > 0:
      let lines = rawDiff.splitLines()
      var fileDiff: FileDiff = nil
      var chunk = Chunk()
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
            if chunk.deleteCount != 0:
              fileDiff.chunks.add(chunk)
              chunk = Chunk()
          fileDiff = FileDiff()
          result.files.add(fileDiff)
        elif line.startsWith("@@ -"):
          if chunk.deleteCount != 0:
            if not fileDiff.isNil:
              fileDiff.chunks.add(chunk)
          let tokens = line.splitWhitespace()
          chunk = Chunk()
          # @@ -deleteFrom,deleteCount +addFrom,addCount @@
          let deleteToken = tokens[1][1..^1].split(",")
          chunk.deleteFrom = deleteToken[0].parseInt
          chunk.deleteCount = deleteToken[1].parseInt
          let addToken = tokens[2][1..^1].split(",")
          chunk.addFrom = addToken[0].parseInt
          chunk.addCount = addToken[1].parseInt
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
              chunk.lines.add(DiffLine(kind: kind, text: line[1..^1]))
      if not fileDiff.isNil:
        if chunk.deleteCount != 0:
          fileDiff.chunks.add(chunk)

# ct replay can take and pass to index; index can send diff to frontend and keep info (or send trace id) there
# when replaying, we can import; or we can abstract, so we don't need to always import (for now we can import)
# and from id-s send and make it work on frontend by replacing trace info
# vibe coding;

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

