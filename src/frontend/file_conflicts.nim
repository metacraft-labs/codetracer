type
  ExternalChangeDecision* = enum
    ecdReload
    ecdPrompt

  FileConflictAction* = enum
    fcaDiscardMemory
    fcaSaveMemory
    fcaOpenMerge
    fcaKeepEditing

proc classifyExternalChange*(bufferChanged: bool): ExternalChangeDecision =
  if bufferChanged:
    ecdPrompt
  else:
    ecdReload

proc buildThreeWayMergeDocument*(path, base, ours, theirs: string): string =
  result = "CodeTracer three-way merge\n"
  result.add "Path: " & path & "\n\n"
  result.add "======= BASE: last synchronized version =======\n"
  result.add base
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"
  result.add "\n======= OURS: in-memory CodeTracer buffer =======\n"
  result.add ours
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"
  result.add "\n======= THEIRS: current disk version =======\n"
  result.add theirs
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"
