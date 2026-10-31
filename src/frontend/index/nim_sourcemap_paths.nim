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
