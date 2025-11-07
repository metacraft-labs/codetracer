import std/strutils

proc normalizePathString*(path: string): string =
  var normalized = path.strip(chars = Whitespace)
  if normalized.len == 0:
    return normalized
  for i in 0 ..< normalized.len:
    if normalized[i] == '\\':
      normalized[i] = '/'
  let hasDrive = normalized.len >= 2 and normalized[1] == ':'
  while normalized.len > 1 and normalized[^1] == '/':
    if hasDrive and normalized.len == 3:
      break
    normalized.setLen(normalized.len - 1)
  normalized

proc folderDisplayName*(path: string): string =
  let normalized = normalizePathString(path)
  if normalized.len == 0:
    return ""
  var endIdx = normalized.len - 1
  while endIdx > 0 and normalized[endIdx] == '/':
    dec endIdx
  var idx = endIdx
  while idx >= 0:
    if normalized[idx] == '/':
      if idx == endIdx:
        return normalized
      return normalized[idx + 1 .. endIdx]
    dec idx
  normalized[0 .. endIdx]

proc joinPath*(base: string; child: string): string =
  if base.len == 0:
    return child
  if base[^1] == '/':
    base & child
  else:
    base & "/" & child

proc toFileUri*(path: string): string =
  var normalized = normalizePathString(path)
  if normalized.len == 0:
    return ""
  if normalized.startsWith("file://"):
    return normalized
  if normalized[0] == '/':
    return "file://" & normalized
  "file:///" & normalized
