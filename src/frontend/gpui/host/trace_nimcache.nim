## gpui/host/trace_nimcache.nim — the generated C a `ct record` recording of
## a Nim program keeps in its own folder, for View › View Generated C Source
## (`GUI/Debugging-Features/Generated-Code-Listing.md` §13.4, "Where the C
## comes from").
##
## `ct record main.nim` compiles with CodeTracer's Nim and `--sourcemap:on`
## into `<trace>/nimcache/` (`ct/trace/recorder_dispatch.nimNativeCompileArgs`),
## so the C files and the `.c.map` Source Maps beside them travel with the
## recording. The recording's FILE TREE does not carry all of it: measured
## 2026-11-13 on a `ct record` recording of a Nim program (MCR, `ct-mcr` from
## codetracer-native-recorder's `ct_cli`), `files/` bundles the C files the
## DWARF names under their recorded absolute paths, and none of the maps,
## which no debug information names. Without the maps the codetracer
## compiler's C, which carries no `#line` directives, cannot be mapped back
## (`nim_c_producer`). In the same measurement the replay server's source
## provider did serve the maps, read at their recorded paths — which are in
## the trace folder, so that holds while the folder is where it was
## recorded; a provider that serves only what the recording bundles answers
## nothing for them.
##
## So the window offers the presenter the recording's `nimcache/` files as
## candidates beside its file tree (`nimcacheCandidates`) and, when its
## source provider cannot serve one of them or its map, reads it from the
## trace folder (`nimcacheFileFor`). Only generated-C artefacts INSIDE the
## trace folder are read: the fallback is for the recording's own nimcache,
## not a way to read any path a listing names. The desktop's precedent for
## the same discovery is `index/nim_sourcemap_paths.findSourcemapPaths`.

import std/[algorithm, os, strutils]

import ../../viewmodel/viewmodels/nim_c_producer

const NimcacheDir* = "nimcache"
  ## The trace folder's subfolder `ct record` keeps a Nim program's C in.

proc isNimcacheArtefact(path: string): bool =
  ## A generated C file or its Source Map (`nim_c_producer.mapPathOf`).
  isGeneratedNimC(path) or path.endsWith(".nim.c.map")

proc nimcacheCFiles*(traceDir: string): seq[string] =
  ## The generated C files in `<traceDir>/nimcache/`, sorted (so the
  ## presenter's choice among equally good candidates does not depend on the
  ## directory's order); none when the recording keeps no nimcache.
  if traceDir.len == 0:
    return
  let dir = traceDir / NimcacheDir
  if not dirExists(dir):
    return
  for kind, f in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and isGeneratedNimC(f):
      result.add f
  result.sort()

proc nimcacheCandidates*(traceDir: string;
                         recorded: openArray[string]): seq[string] =
  ## The recording's file list (`recorded`) with its nimcache's C files
  ## added: each one whose file name the list does not already hold. A C
  ## file the tree names is kept under the tree's path — the provider serves
  ## it there, and `nimcacheFileFor` finds its map by its name.
  result = @recorded
  var names: seq[string] = @[]
  for f in recorded:
    if isGeneratedNimC(f):
      names.add f.extractFilename
  for f in nimcacheCFiles(traceDir):
    if f.extractFilename notin names:
      result.add f

proc isInside(path, dir: string): bool =
  let p = absolutePath(path).normalizedPath
  let d = absolutePath(dir).normalizedPath
  p.startsWith(d & DirSep)

proc nimcacheFileFor*(traceDir, path: string): string =
  ## Where the trace folder holds `path` — a generated C file or its map —
  ## or "" when it does not: `path` itself when it is inside the trace
  ## folder, else the file of that name in its nimcache (the recording was
  ## made elsewhere and its paths name the folder it was made in).
  if traceDir.len == 0 or not isNimcacheArtefact(path):
    return ""
  if path.isAbsolute and path.isInside(traceDir) and fileExists(path):
    return path
  let local = traceDir / NimcacheDir / path.extractFilename
  if fileExists(local): local else: ""
