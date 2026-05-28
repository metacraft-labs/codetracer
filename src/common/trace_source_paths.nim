import std/strutils

proc normalizeSourcePath(path: string): string =
  path.replace('\\', '/')

proc normalizeForCompare(path: string): string =
  normalizeSourcePath(path).strip(leading = false, trailing = true, chars = {'/'})

proc isAbsoluteTraceSourcePath*(path: string): bool =
  ## Check if a trace source path is absolute on Unix or Windows.
  if path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    return true
  path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')

proc stripTraceSourceRoot*(path: string): string =
  ## Strip an OS root/drive so an absolute source path can be placed below
  ## a self-contained trace's ``files/`` directory.
  let normalized = normalizeSourcePath(path)
  if normalized.len >= 3 and normalized[1] == ':' and normalized[2] == '/':
    normalized[3 .. ^1]
  elif normalized.len > 0 and normalized[0] == '/':
    normalized[1 .. ^1]
  else:
    normalized

proc dropTraceFilesPrefix(path: string): string =
  let normalized = normalizeSourcePath(path)
  if normalized.startsWith("files/"):
    normalized["files/".len .. ^1]
  else:
    normalized

proc addPayloadCandidate(candidates: var seq[string]; path: string) =
  var candidate = dropTraceFilesPrefix(path)
  while candidate.startsWith("./"):
    candidate = candidate[2 .. ^1]
  candidate = candidate.strip(leading = true, trailing = true, chars = {'/'})
  if candidate.len == 0 or candidate == ".":
    return
  for existing in candidates:
    if existing == candidate:
      return
  candidates.add(candidate)

proc relativePathInsideRoot(path, root: string): string =
  let normalizedPath = normalizeForCompare(path)
  let normalizedRoot = normalizeForCompare(root)
  if normalizedPath.len == 0 or normalizedRoot.len == 0:
    return ""
  if normalizedPath == normalizedRoot:
    return ""
  let prefix = normalizedRoot & "/"
  if normalizedPath.startsWith(prefix):
    normalizedPath[prefix.len .. ^1]
  else:
    ""

proc selfContainedSourcePayloadCandidates*(
    filename, workdir: string,
    sourceFolders: openArray[string] = []): seq[string] =
  ## Return relative payload paths to try under a self-contained trace's
  ## ``files/`` directory for a source location reported by the replay backend.
  ##
  ## Older self-contained traces stored absolute source paths by stripping
  ## the filesystem root (``/workspace/src/main.c`` ->
  ## ``files/workspace/src/main.c``). Newer portable recorders can store
  ## paths relative to the recorded workdir (``files/src/main.nr``), while
  ## the debugger still reports absolute source locations. Try both forms.
  let normalized = normalizeSourcePath(filename)
  if normalized.len == 0:
    return

  if isAbsoluteTraceSourcePath(normalized):
    result.addPayloadCandidate(stripTraceSourceRoot(normalized))

    let workdirRelative = relativePathInsideRoot(normalized, workdir)
    if workdirRelative.len > 0:
      result.addPayloadCandidate(workdirRelative)

    for folder in sourceFolders:
      let folderRelative = relativePathInsideRoot(normalized, folder)
      if folderRelative.len > 0:
        result.addPayloadCandidate(folderRelative)
  else:
    result.addPayloadCandidate(normalized)
