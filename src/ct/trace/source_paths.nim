import std/os

proc isAbsoluteTracePath*(path: string): bool =
  ## Check if path is absolute on either Unix or Windows.
  if path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    return true
  path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')

proc stripTracePathRoot*(path: string): string =
  ## Strip the root/drive from an absolute path for use as a relative sub-path.
  ## Unix: /path/to/file -> path/to/file
  ## Windows: D:\path\to\file -> path\to\file
  if path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/'):
    path[3..^1]
  elif path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    path[1..^1]
  else:
    path

proc resolveTraceSourcePath*(path, workdir: string): string =
  ## Trace path metadata can contain either absolute paths or paths relative to
  ## the recorded process workdir.  The self-contained trace payload under
  ## ``files/`` must be built from the real source file path in both cases.
  if path.len == 0 or isAbsoluteTracePath(path) or workdir.len == 0:
    path
  else:
    workdir / path

proc tracePayloadRelativePath*(path, workdir: string): string =
  ## Preserve relative trace paths as relative payload paths. Absolute paths
  ## still get rooted under ``files/`` by stripping the filesystem root, which
  ## matches the legacy self-contained trace layout.
  if path.len == 0:
    ""
  elif isAbsoluteTracePath(path):
    stripTracePathRoot(path)
  else:
    path
