import std / [os, osproc, strformat, sequtils, strutils]
import json_serialization
import .. / .. / common / trace_index

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
    # TODO lines*: seq[]


proc parseDiff(rawDiff: string): Diff =
    result = Diff()
    if rawDiff.len > 0:
      # TODO most
      let lines = rawDiff.splitLines()
      var fileDiff: FileDiff = nil
      var chunk = Chunk()
      for line in lines:
        if line.startsWith("--- a/"):
          let path = line["--- a/".len .. ^1]
          fileDiff.previousPath = path
        elif line.startsWith("+++ b/"):
          let path = line["+++ b/".len .. ^1]
          fileDiff.currentPath = path
        elif line.startsWith("diff "):
          if not fileDiff.isNil:
            if chunk.deleteCount != 0:
              fileDiff.chunks.add(chunk)
            result.files.add(fileDiff)
          fileDiff = FileDiff()
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
          echo "TODO ", line

proc makeMultitraceArchive(traceFolders: seq[string], structuredDiff: Diff, outputPath: string) =
  echo Json.encode(structuredDiff)
  quit(1)

proc makeMultitrace*(traceIdList: seq[int], diffSpecification: string, outputPath: string) =
  # make a folder , copy those traces , find this diff, eventually parse it and store it
  # TODO: eventually diff-index in the future
  # in the future store as a new trace-id?
  # for now in a custom place
  
  # find the diff, parse
  let rawDiff = findDiff(diffSpecification)
  echo rawDiff
  let structuredDiff = parseDiff(rawDiff)
  let traceFolders = traceIdList.mapIt(trace_index.find(it, test=false).outputFolder)
  makeMultitraceArchive(traceFolders, structuredDiff, outputPath)
  echo fmt"OK: created multitrace in {outputPath}"
