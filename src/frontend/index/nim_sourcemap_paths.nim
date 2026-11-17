## Main-process discovery shared by desktop and hosted trace loading.
import std/[os, strutils, algorithm, jsffi]
import ../lib/electron_lib
import ../../common/ct_logging

proc findSourcemapPaths*(outputFolder: cstring): seq[cstring] =
  ## A current Nim compilation emits one Source Map V3 sidecar per generated
  ## C module. Send all of them to the renderer; the retired aggregate is not
  ## a substitute for the per-module maps.
  let nimcacheDir = cstring($outputFolder / "nimcache")
  if not fs.existsSync(nimcacheDir):
    return @[]
  try:
    for entry in fs.readdirSync(nimcacheDir):
      if ($entry).endsWith(".c.map"):
        let path = cstring($nimcacheDir / $entry)
        if fs.statSync(path).isFile().to(bool):
          result.add(path)
    result.sort(proc(a, b: cstring): int = cmp($a, $b))
  except:
    warnPrint "failed to scan nimcache for sourcemaps: ", getCurrentExceptionMsg()

proc findNimcacheCPaths*(outputFolder: cstring): seq[cstring] =
  ## The generated C files a `ct record` recording of a Nim program keeps in
  ## `<trace>/nimcache/` (`<module>.nim.c`, beside its `.c.map`): the
  ## candidates View Generated C Source picks the C of a Nim source from
  ## (Generated-Code-Listing §13.4). The recording's file tree and its
  ## replay's source provider need not serve them, or their maps, so the
  ## renderer is told where they are on disk, as it is told the maps' paths.
  let nimcacheDir = cstring($outputFolder / "nimcache")
  if not fs.existsSync(nimcacheDir):
    return @[]
  try:
    for entry in fs.readdirSync(nimcacheDir):
      if ($entry).endsWith(".nim.c"):
        let path = cstring($nimcacheDir / $entry)
        if fs.statSync(path).isFile().to(bool):
          result.add(path)
    result.sort(proc(a, b: cstring): int = cmp($a, $b))
  except:
    warnPrint "failed to scan nimcache for generated C: ", getCurrentExceptionMsg()
