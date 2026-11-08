## content_file_cache.nim — small generated files, written once per user
## and reused, named by what they contain.
##
## The GPUI front-end draws an icon through the shim's `img` or a
## `mask-image`, both of which load a picture from a PATH, so every icon it
## generates (the Agent Harbor "+" mask, a recoloured close mark, ...) has to
## exist as a file. A directory of its own named after the process id under
## the system temp directory, which the shell's leaves still use, is a new
## directory per process that is never removed: every GPUI window, story
## capture and test run leaves one behind.
##
## Here a file is named by a digest of its content and lives in the per-user
## cache (`ct_home.ctCacheDir`, which `CODETRACER_HOME` relocates, so tests
## stay out of the real one). The same content always lands at the same
## path, in every process, so the set of files is bounded by the distinct
## icons ever drawn, and a different content can never be read through a
## path GPUI has cached for another.
##
## A file is written to a private temporary name and renamed into place
## (`moveFile`, a `rename(2)` within one directory, which is atomic on
## POSIX: https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html),
## so a concurrent reader sees the whole file or none. Before a path is
## handed out for the first time in a process its bytes are compared with
## the content, so a stale, truncated or colliding file is rewritten rather
## than drawn. Errors are not swallowed: a cache that cannot be written
## raises the `OSError` / `IOError` of the failing call.

import std/[os, strutils, tables]

import ./ct_home

proc fnv1a64(s: string): uint64 =
  ## FNV-1a, 64-bit (http://www.isthe.com/chongo/tech/comp/fnv/#FNV-1a):
  ## stable across Nim versions, unlike `std/hashes`, so a path stays the same
  ## from one build to the next. Not a cryptographic digest and not used as
  ## one: a path's bytes are compared with the content before it is used.
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor uint64(ord(c))) * 0x100000001b3'u64

proc contentFileName*(name, content: string): string =
  ## The file name `content` is stored under: `name`'s stem, the content's
  ## digest, `name`'s extension (`plus-b0b0b0.svg` ->
  ## `plus-b0b0b0-<16 hex>.svg`). The extension is kept because the loader
  ## picks a decoder by it (GPUI's `img`: a raster format it knows by its
  ## extension, anything else as SVG).
  let (_, stem, ext) = splitFile(name)
  stem & "-" & toHex(fnv1a64(content)).toLowerAscii & ext

proc contentFileDir*(area: string): string =
  ## Where the files of `area` live: `<ctCacheDir>/<area>`.
  ctCacheDir() / area

var verified {.threadvar.}: Table[string, bool]
  ## Paths whose bytes this thread has compared with their content, so a
  ## renderer that asks every frame reads each file once per process (and
  ## only stats it after that).

proc contentFile*(area, name, content: string): string =
  ## The path of a file holding exactly `content`, under `area` in the
  ## per-user cache; written if it is missing or holds anything else.
  ## `area` and `name` must be plain file names (no directory separators):
  ## they are joined into a path, never interpreted.
  if area.len == 0 or name.len == 0 or
      area.contains({DirSep, AltSep}) or name.contains({DirSep, AltSep}) or
      area in [".", ".."] or name in [".", ".."]:
    raise newException(ValueError,
      "contentFile: area and name must be plain file names, got '" & area &
      "' and '" & name & "'")
  let dir = contentFileDir(area)
  result = dir / contentFileName(name, content)
  # A path this thread has verified is handed out again without reading it,
  # unless the file has gone since (a cleaned cache), which rewrites it.
  if verified.getOrDefault(result) and fileExists(result): return
  if not (fileExists(result) and readFile(result) == content):
    createDir(dir)
    let partial = result & ".partial-" & $getCurrentProcessId()
    try:
      writeFile(partial, content)
      moveFile(partial, result)
    finally:
      # Gone after a successful rename; left behind only by a failed write.
      if fileExists(partial): removeFile(partial)
  verified[result] = true
