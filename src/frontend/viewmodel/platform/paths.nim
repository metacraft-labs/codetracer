## Pure path arithmetic — the part of `std/os` that touches no host.
##
## ## Why this exists rather than `import std/os`
##
## The host-free build (`ci/hostfree/`) replaces `std/os` so that a direct
## `getCurrentDir` or `walkDir` in front-end code is a compile error. But
## `joinPath`, `parentDir` and `splitFile` are *string* functions — they read no
## filesystem, they spawn nothing, and banning them would push callers into
## hand-rolled string surgery, which is worse than what NS1 is trying to fix.
##
## So the replacement `os` module re-exports this one, and front-end code keeps
## its path vocabulary while losing its host access. Everything here is
## deliberately self-contained: it imports no stdlib module that could
## re-introduce a host call through the back door.
##
## ## Why the semantics are normalised rather than native
##
## The facade serves three instantiations. A web project store (Noir-Studio.md
## §4) and a container filesystem both address entries with `/`-separated
## relative paths; only the desktop has drive letters and backslashes. Rather
## than three path dialects, there is one: `/` is always a separator, `\` is
## additionally a separator on Windows-shaped input, and the canonical output
## separator is `/`. Desktop code that needs a native path for an exec call
## gets it from the facade's process module, which is the only layer that has
## to care.

const
  DirSep* = '/'
  AltSep* = '\\'
  ExtSep* = '.'
  CurDir* = "."
  ParDir* = ".."

func startsWith(s, prefix: string): bool =
  ## Local, so this module imports nothing at all — a facade that leans on
  ## `std/strutils` for one predicate is one `import` away from leaning on
  ## `std/os` for the next.
  if prefix.len > s.len: return false
  for i in 0 ..< prefix.len:
    if s[i] != prefix[i]: return false
  true

func isSep*(c: char): bool =
  c == DirSep or c == AltSep

func endsWithSep*(path: string): bool =
  path.len > 0 and path[^1].isSep

func hasDriveLetter*(path: string): bool =
  ## `C:` style prefix. Recognised on every platform so that a desktop-produced
  ## path stays intelligible when it is logged or shared with a container.
  path.len >= 2 and path[1] == ':' and
    ((path[0] >= 'a' and path[0] <= 'z') or (path[0] >= 'A' and path[0] <= 'Z'))

func isAbsolute*(path: string): bool =
  if path.len == 0: false
  elif path[0].isSep: true
  else: hasDriveLetter(path) and (path.len == 2 or path[2].isSep)

func splitDrive*(path: string): tuple[drive, rest: string] =
  if hasDriveLetter(path): (path[0 .. 1], path[2 .. ^1])
  else: ("", path)

func lastSepIndex(path: string): int =
  result = -1
  for i in countdown(path.high, 0):
    if path[i].isSep:
      return i

func splitPath*(path: string): tuple[head, tail: string] =
  ## `"a/b/c"` -> `("a/b", "c")`. A trailing separator yields an empty tail,
  ## matching `std/os`.
  let (drive, rest) = splitDrive(path)
  let i = lastSepIndex(rest)
  if i < 0:
    result = (drive, rest)
  elif i == 0:
    result = (drive & rest[0 .. 0], rest[1 .. ^1])
  else:
    result = (drive & rest[0 ..< i], rest[i + 1 .. ^1])

func parentDir*(path: string): string =
  ## The directory containing `path`. A trailing separator is ignored, so
  ## `parentDir("a/b/")` is `"a"` and not `"a/b"` — the `std/os` behaviour
  ## callers already rely on.
  var trimmed = path
  while trimmed.len > 1 and trimmed[^1].isSep:
    trimmed.setLen(trimmed.len - 1)
  result = splitPath(trimmed).head

func extractFilename*(path: string): string =
  if endsWithSep(path): "" else: splitPath(path).tail

func lastPathPart*(path: string): string =
  ## Like `extractFilename` but a trailing separator does not erase the answer.
  var trimmed = path
  while trimmed.len > 1 and trimmed[^1].isSep:
    trimmed.setLen(trimmed.len - 1)
  splitPath(trimmed).tail

func searchExtPos*(path: string): int =
  ## Index of the extension's `.`, or -1. A leading dot is a hidden-file marker
  ## rather than an extension, so `".bashrc"` has none.
  result = -1
  let name = lastPathPart(path)
  if name.len < 2: return
  let offset = path.len - name.len
  for i in countdown(name.high, 1):
    if name[i] == ExtSep:
      return offset + i
    elif name[i].isSep:
      return -1

func splitFile*(path: string): tuple[dir, name, ext: string] =
  let (head, tail) = splitPath(path)
  let dotIdx = searchExtPos(path)
  if dotIdx < 0:
    (head, tail, "")
  else:
    let nameLen = tail.len - (path.len - dotIdx)
    (head, tail[0 ..< nameLen], path[dotIdx .. ^1])

func changeFileExt*(path, ext: string): string =
  let i = searchExtPos(path)
  let stem = if i < 0: path else: path[0 ..< i]
  if ext.len == 0: stem
  elif ext[0] == ExtSep: stem & ext
  else: stem & ExtSep & ext

func addFileExt*(path, ext: string): string =
  if searchExtPos(path) >= 0: path else: changeFileExt(path, ext)

func joinPath*(head, tail: string): string =
  ## Normalises the seam only. Neither side is otherwise rewritten, so a caller
  ## that built a path deliberately gets it back.
  if head.len == 0: return tail
  if tail.len == 0: return head
  if isAbsolute(tail): return tail
  var h = head
  while h.len > 1 and h[^1].isSep:
    h.setLen(h.len - 1)
  if h.len == 1 and h[0].isSep:
    return h & tail
  var t = tail
  var start = 0
  while start < t.len and t[start].isSep:
    inc start
  h & DirSep & t[start .. ^1]

func joinPath*(parts: varargs[string]): string =
  for part in parts:
    result = joinPath(result, part)

func `/`*(head, tail: string): string {.inline.} =
  joinPath(head, tail)

func normalizePath*(path: string): string =
  ## Collapse `.`, resolve `..` textually, squeeze repeated separators and
  ## canonicalise on `/`. Textual by design: resolving `..` against real
  ## symlinks needs the host, which is the facade's `realPath` and not this
  ## module's business.
  let (drive, rest) = splitDrive(path)
  let rooted = rest.len > 0 and rest[0].isSep
  var parts: seq[string] = @[]
  var current = ""
  for c in rest:
    if c.isSep:
      if current.len > 0:
        parts.add(current)
        current = ""
    else:
      current.add(c)
  if current.len > 0:
    parts.add(current)

  var stack: seq[string] = @[]
  for part in parts:
    if part == CurDir:
      discard
    elif part == ParDir:
      if stack.len > 0 and stack[^1] != ParDir:
        discard stack.pop()
      elif not rooted:
        stack.add(ParDir)
    else:
      stack.add(part)

  result = drive
  if rooted:
    result.add(DirSep)
  for i, part in stack:
    if i > 0: result.add(DirSep)
    result.add(part)
  if result.len == 0:
    result = CurDir

func relativePath*(path, base: string): string =
  ## `path` expressed relative to `base`, or `path` unchanged when the two live
  ## on different roots (different drives, or one absolute and one not).
  if base.len == 0: return path
  let np = normalizePath(path)
  let nb = normalizePath(base)
  if isAbsolute(np) != isAbsolute(nb): return np
  if splitDrive(np).drive != splitDrive(nb).drive: return np

  func segments(p: string): seq[string] =
    result = @[]
    var current = ""
    for c in splitDrive(p).rest:
      if c.isSep:
        if current.len > 0:
          result.add(current)
          current = ""
      else:
        current.add(c)
    if current.len > 0: result.add(current)

  let ps = segments(np)
  let bs = segments(nb)
  var common = 0
  while common < ps.len and common < bs.len and ps[common] == bs[common]:
    inc common
  var pieces: seq[string] = @[]
  for _ in common ..< bs.len:
    pieces.add(ParDir)
  for i in common ..< ps.len:
    pieces.add(ps[i])
  if pieces.len == 0: CurDir else: joinPath(pieces)

func isParentOf*(parent, child: string): bool =
  ## Containment, decided on normalised segments rather than on string prefix.
  ## A prefix test answers yes for `("/a/b", "/a/bc")`, which is how directory
  ## sandboxes leak.
  let p = normalizePath(parent)
  let c = normalizePath(child)
  if p == c: return false
  if p.len == 0: return false
  if not c.startsWith(p): return false
  result = p.endsWithSep or (c.len > p.len and c[p.len].isSep)
