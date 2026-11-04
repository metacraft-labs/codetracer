## Makes a design brief readable by the IsoNim Editor instance.
##
## The editor resolves the brief of the selected story from an index of
## briefs with YAML frontmatter (`coversPreviews` names the stories a brief
## covers). CodeTracer's design briefs are plain review briefs read by review
## agents, and one of them is private, so it cannot be given frontmatter in
## this repository. This tool writes, into a git-ignored build directory, an
## editor copy of a brief: frontmatter whose `coversPreviews` lists every
## story of one editor group from the story declaration
## (`src/frontend/stories/codetracer_stories.nim`), followed by the brief's
## text unchanged. The copy is what the editor's Spec pane shows for those
## stories; its `sourceBrief` key names the brief it was made from, which
## stays the only one to edit (the copy is rewritten on every editor build).
##
##   nim r tools/stories/emit_editor_brief.nim --brief:<file.md>
##     --group:<editor group> --id:<briefId> --out:<file.md>
##
## Brief format: https://github.com/metacraft-labs/isonim, editor design
## review (`src/isonim/editor/design_review/brief_format.nim`).

import std/[os, parseopt, strutils]
import ../../src/frontend/stories/codetracer_stories

proc yamlString(s: string): string =
  ## A double-quoted YAML scalar (the subset `brief_format` parses).
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc titleOf(body: string): string =
  for line in body.splitLines:
    if line.startsWith("# "): return line[2 .. ^1].strip
  ""

proc editorBrief*(sections: seq[CodeTracerStorySection]; group, briefId,
                  sourcePath, body: string): string =
  ## The editor copy of the brief `body` (read from `sourcePath`), covering
  ## every story of `group`. Raises when the group is unknown or empty, so a
  ## renamed group cannot leave the brief covering nothing unnoticed.
  var covers: seq[string]
  for section in sections:
    if section.group != group: continue
    for index, story in section.stories:
      covers.add "  - storyRef: { group: " & yamlString(group) & ", name: " &
        yamlString(story.name) & ", kind: component, index: " & $index & " }\n" &
        "    backends: [web]"
  if covers.len == 0:
    raise newException(ValueError, "no stories in editor group " & group)
  if body.startsWith("---"):
    raise newException(ValueError, sourcePath & " already has frontmatter")
  let title = titleOf(body)
  result = "---\n" &
    "briefId: " & briefId & "\n" &
    "schemaVersion: 1\n" &
    "kind: render\n" &
    "title: " & yamlString(if title.len > 0: title else: group) & "\n" &
    "coversPreviews:\n" & covers.join("\n") & "\n" &
    # The brief's named sizes (`panel`, `sidebar`, `laptop`).
    "captureViewports:\n" &
    "  - { width: 760, height: 640, label: \"panel\" }\n" &
    "  - { width: 360, height: 900, label: \"sidebar\" }\n" &
    "  - { width: 1440, height: 900, label: \"laptop\" }\n" &
    "reviewerSchemaVersion: 1\n" &
    "scoringDimensions:\n" &
    "  - { id: rendering, label: \"Meets the brief\", weight: 1.0, scale: { min: 1, max: 10 } }\n" &
    "sourceBrief: " & yamlString(sourcePath) & "\n" &
    "---\n" & body

proc main(): int =
  var brief, group, briefId, outPath: string
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "brief": brief = val
      of "group": group = val
      of "id": briefId = val
      of "out": outPath = val
      else:
        stderr.writeLine "emit_editor_brief: unknown option --" & key
        return 2
    of cmdArgument:
      stderr.writeLine "emit_editor_brief: unexpected argument " & key
      return 2
    of cmdEnd: discard
  if brief.len == 0 or group.len == 0 or briefId.len == 0 or outPath.len == 0:
    stderr.writeLine "usage: emit_editor_brief --brief:<file> --group:<group> --id:<briefId> --out:<file>"
    return 2
  let source = absolutePath(brief)
  try:
    let text = editorBrief(codeTracerStorySections(), group, briefId, source,
                           readFile(source))
    createDir(outPath.parentDir)
    writeFile(outPath, text)
  except CatchableError as error:
    stderr.writeLine "emit_editor_brief: " & error.msg
    return 1
  echo "emit_editor_brief: ", briefId, " covers group ", group, " -> ", outPath
  0

when isMainModule:
  quit(main())
