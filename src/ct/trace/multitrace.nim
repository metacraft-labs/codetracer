import std / [os, osproc, strformat, sequtils, strutils]
import json_serialization, result
import .. / .. / common / trace_index
import .. / .. / common / types
import .. / utilities / [git, zip]
import replay

proc findDiff(diffSpecification: string): string =
  if diffSpecification.len > 0:
    if diffSpecification == "last-commit":
      execProcess(findExe("git"), args = @["diff", "HEAD~..HEAD"], options = {poEchoCmd})
    else:
      var path = diffSpecification
      try:
        # try to support arguments like `~/<path>`
        path = expandFileName(expandTilde(diffSpecification))
      except OsError:
        discard

      if fileExists(path):
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

      let repoRootPathResult = getGitTopLevel(getCurrentDir())
      if not repoRootPathResult.isOk:
        echo "ERROR: maybe not called from a git repo?"
        echo "  error, trying to load the git top level directory: ", repoRootPathResult.error
        quit(1)
      let repoRootPath = repoRootPathResult.value

      for line in lines:
        # echo "line ", line
        if line.startsWith("--- "):
          # for now assume it's relative to the repo root
          let file = if line.startsWith("--- a/"):
              line["--- a/".len .. ^1]
            elif line == "--- /dev/null":
              "" # for now assume this is created
            else:
              # not sure ..  TODO?
              ""
          fileDiff.previousPath = if file.len > 0: repoRootPath / file else: ""
        elif line.startsWith("+++ "):
          # for now assume it's relative to the repo root
          let file = if line.startsWith("+++ b/"):
              line["+++ b/".len .. ^1]
            elif line == "+++ /dev/null":
              "" # for now assume this is deleted
            else:
              # not sure ..  TODO?
              ""
          fileDiff.currentPath = if file.len > 0: repoRootPath / file else: ""
          if fileDiff.currentPath != "" and fileDiff.previousPath != "":
            if fileDiff.previousPath != fileDiff.currentPath:
              fileDiff.change = FileRenamed
            else:
              fileDiff.change = FileChanged
          elif fileDiff.previousPath == "":
            fileDiff.change = FileAdded
          else: # currentPath should be ""
            assert fileDiff.currentPath == ""
            fileDiff.change = FileDeleted

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
          # @@ -previousFrom[,previousCount] +currentFrom[,currentCount] @@
          let previousToken = tokens[1][1..^1].split(",")
          chunk.previousFrom = previousToken[0].parseInt
          chunkPreviousFileLineNumber = chunk.previousFrom
          if previousToken.len > 1:
            chunk.previousCount = previousToken[1].parseInt
          else:
            chunk.previousCount = 1
          let currentToken = tokens[2][1..^1].split(",")
          chunk.currentFrom = currentToken[0].parseInt
          chunkCurrentFileLineNumber = chunk.currentFrom
          if currentToken.len > 1:
            chunk.currentCount = currentToken[1].parseInt
          else:
            chunk.currentCount = 1
        elif line.startsWith("rename "):
          let tokens = line.split(" ", 2)
          let file = tokens[2]
          let direction = tokens[1]
          if direction == "from":
            fileDiff.previousPath = repoRootPath / file
          elif direction == "to":
            fileDiff.currentPath = repoRootPath / file
            fileDiff.change = FileRenamed
          else:
            # not supported/valid?
            discard
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

  # TODO: decide here: only when flag archive? or always? removeDir(folder)

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
